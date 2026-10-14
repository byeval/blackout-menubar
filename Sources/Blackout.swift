import AppKit
import Carbon
import CoreGraphics
import Darwin
import IOKit.pwr_mgt

private struct SavedDisplay: Codable {
    let id: UInt32
    let brightness: Double
    let maximum: Int?
    let isBuiltIn: Bool
}

private final class DisplayHardware {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private let ddcURL: URL

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        if let library,
           let getter = dlsym(library, "DisplayServicesGetBrightness"),
           let setter = dlsym(library, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(getter, to: GetBrightness.self)
            setBrightness = unsafeBitCast(setter, to: SetBrightness.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }
        ddcURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/m1ddc")
    }

    func onlineIDs() -> [UInt32] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func capture(ids: [UInt32]? = nil) -> [SavedDisplay] {
        (ids ?? onlineIDs()).compactMap { id in
            if CGDisplayIsBuiltin(id) != 0 {
                var value: Float = 0
                guard let getBrightness, getBrightness(id, &value) == 0 else { return nil }
                return SavedDisplay(id: id, brightness: Double(value), maximum: nil, isBuiltIn: true)
            }
            guard let current = Int(runDDC(["display", "id=\(id)", "get", "luminance"]) ?? ""),
                  let maximum = Int(runDDC(["display", "id=\(id)", "max", "luminance"]) ?? ""),
                  maximum > 0 else { return nil }
            return SavedDisplay(id: id, brightness: Double(current), maximum: maximum, isBuiltIn: false)
        }
    }

    @discardableResult
    func dim(_ displays: [SavedDisplay], percent: Int) -> [UInt32] {
        var failures: [UInt32] = []
        for display in displays {
            if display.isBuiltIn {
                if setBrightness?(display.id, Float(percent) / 100) != 0 { failures.append(display.id) }
            } else if let maximum = display.maximum {
                let value = max(1, Int((Double(maximum) * Double(percent) / 100).rounded()))
                if runDDC(["display", "id=\(display.id)", "set", "luminance", "\(value)"]) == nil {
                    failures.append(display.id)
                }
            }
        }
        return failures
    }

    @discardableResult
    func restore(_ displays: [SavedDisplay]) -> [UInt32] {
        var failures: [UInt32] = []
        for display in displays {
            if display.isBuiltIn {
                if setBrightness?(display.id, Float(display.brightness)) != 0 { failures.append(display.id) }
            } else if runDDC(["display", "id=\(display.id)", "set", "luminance", "\(Int(display.brightness))"]) == nil {
                failures.append(display.id)
            }
        }
        return failures
    }

    private func runDDC(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: ddcURL.path) else { return nil }
        let task = Process()
        task.executableURL = ddcURL
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.hasPrefix("DDC communication failure") ? nil : result
        } catch { return nil }
    }
}

private final class BlackWindow: NSWindow {
    var restoreAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func mouseDown(with event: NSEvent) { restoreAction?() }
    override func keyDown(with event: NSEvent) { restoreAction?() }
}

private final class BlackoutApp: NSObject, NSApplicationDelegate {
    private let hardware = DisplayHardware()
    private let hardwareQueue = DispatchQueue(label: "blackout.hardware", qos: .userInitiated)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var windows: [BlackWindow] = []
    private var saved: [SavedDisplay] = []
    private var pendingDisplayIDs: Set<UInt32> = []
    private var active = false
    private var transitioning = false
    private var assertionID = IOPMAssertionID(0)
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var message: String?

    private var saveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackoutMenubar", isDirectory: true)
            .appendingPathComponent("brightness.json")
    }

    private var lowPercent: Int {
        let value = UserDefaults.standard.integer(forKey: "lowPercent")
        return [1, 5, 10].contains(value) ? value : 5
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "黑屏低亮度")
        statusItem.button?.image?.isTemplate = true
        installHotKey()
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if loadSnapshot() != nil { retryRestore(nil) }

        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-seconds=") }),
           let seconds = TimeInterval(argument.dropFirst("--demo-seconds=".count)), seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.enterBlackout(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) { self.restoreDisplay(nil) }
        }
    }

    private func installHotKey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let app = Unmanaged<BlackoutApp>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.toggle() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x424C4B54, id: 1)
        let registrationStatus = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey | controlKey), id,
                                                      GetApplicationEventTarget(), 0, &hotKey)
        if handlerStatus != noErr || registrationStatus != noErr {
            message = "快捷键注册失败；点击黑屏仍可恢复"
            NSLog("Blackout hotkey registration failed: handler=%d registration=%d", handlerStatus, registrationStatus)
        }
    }

    private func toggle() {
        if active { restoreDisplay(nil) } else { enterBlackout(nil) }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let enter = NSMenuItem(title: "进入黑屏低亮度", action: #selector(enterBlackout(_:)), keyEquivalent: "")
        enter.target = self
        enter.isEnabled = !active && !transitioning
        menu.addItem(enter)
        let restore = NSMenuItem(title: "恢复显示", action: #selector(restoreDisplay(_:)), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = active
        menu.addItem(restore)
        if !active && !transitioning && loadSnapshot() != nil {
            let retry = NSMenuItem(title: "重试恢复原亮度", action: #selector(retryRestore(_:)), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())
        let level = NSMenuItem(title: "低亮度", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for percent in [1, 5, 10] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(selectBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = percent == lowPercent ? .on : .off
            levels.addItem(item)
        }
        level.submenu = levels
        menu.addItem(level)
        let hint = NSMenuItem(title: "点击黑屏或按 ⌃⌥⌘B 恢复", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if let message {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func selectBrightness(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "lowPercent")
        if active {
            let current = saved
            hardwareQueue.async { _ = self.hardware.dim(current, percent: sender.tag) }
        }
        rebuildMenu()
    }

    @objc private func enterBlackout(_ sender: Any?) {
        guard !active && !transitioning else { return }
        transitioning = true
        message = "正在读取显示器亮度…"
        rebuildMenu()
        hardwareQueue.async {
            let snapshot = self.hardware.capture()
            DispatchQueue.main.async {
                guard self.persist(snapshot) else {
                    self.transitioning = false
                    self.message = "无法保存原亮度，未进入黑屏"
                    self.rebuildMenu()
                    return
                }
                self.saved = snapshot
                self.active = true
                self.message = snapshot.isEmpty ? "仅用黑色遮罩，硬件调光不可用" : nil
                self.showWindows()
                self.preventDisplaySleep()
                self.rebuildMenu()
                self.hardwareQueue.async {
                    let failures = self.hardware.dim(snapshot, percent: self.lowPercent)
                    DispatchQueue.main.async {
                        self.transitioning = false
                        if !failures.isEmpty { self.message = "部分屏幕仅用黑色遮罩，硬件调光不可用" }
                        self.rebuildMenu()
                    }
                }
            }
        }
    }

    @objc private func restoreDisplay(_ sender: Any?) {
        guard active else { return }
        active = false
        transitioning = true
        hideWindows()
        allowDisplaySleep()
        message = "正在恢复亮度…"
        rebuildMenu()
        let snapshot = saved
        hardwareQueue.async {
            let failures = self.hardware.restore(snapshot)
            DispatchQueue.main.async {
                self.transitioning = false
                self.message = failures.isEmpty ? nil : "部分显示器未能恢复，请检查连接后重试"
                if failures.isEmpty { self.removeSnapshot() }
                self.saved = []
                self.rebuildMenu()
            }
        }
    }

    @objc private func retryRestore(_ sender: Any?) {
        guard !active, !transitioning, let snapshot = loadSnapshot() else { return }
        transitioning = true
        message = "正在恢复上次的亮度…"
        rebuildMenu()
        hardwareQueue.async {
            let failures = self.hardware.restore(snapshot)
            DispatchQueue.main.async {
                self.transitioning = false
                self.message = failures.isEmpty ? nil : "部分显示器未能恢复，请检查连接后重试"
                if failures.isEmpty { self.removeSnapshot() }
                self.rebuildMenu()
            }
        }
    }

    private func showWindows() {
        hideWindows()
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            // screen.frame is already in global coordinates. Passing screen here offsets
            // the rectangle a second time on secondary displays.
            let window = BlackWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.restoreAction = { [weak self] in self?.restoreDisplay(nil) }
            window.orderFrontRegardless()
            window.makeKey()
            windows.append(window)
        }
    }

    private func hideWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    @objc private func displaysChanged() {
        guard active else { return }
        showWindows()
        let known = Set(saved.map(\.id))
        let newIDs = hardware.onlineIDs().filter { !known.contains($0) && !pendingDisplayIDs.contains($0) }
        pendingDisplayIDs.formUnion(newIDs)
        hardwareQueue.async {
            let added = self.hardware.capture(ids: newIDs)
            DispatchQueue.main.async {
                self.pendingDisplayIDs.subtract(newIDs)
                guard self.active else { return }
                guard !added.isEmpty else { return }
                self.saved += added
                if self.persist(self.saved) {
                    self.hardwareQueue.async { _ = self.hardware.dim(added, percent: self.lowPercent) }
                }
            }
        }
    }

    private func preventDisplaySleep() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Blackout keeps displays on" as CFString, &assertionID)
    }

    private func allowDisplaySleep() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
    }

    private func persist(_ snapshot: [SavedDisplay]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: saveURL, options: .atomic)
            return true
        } catch { return false }
    }

    private func loadSnapshot() -> [SavedDisplay]? {
        guard let data = try? Data(contentsOf: saveURL) else { return nil }
        return try? JSONDecoder().decode([SavedDisplay].self, from: data)
    }

    private func removeSnapshot() { try? FileManager.default.removeItem(at: saveURL) }

    @objc private func quit(_ sender: Any?) {
        if active {
            active = false
            hideWindows()
            allowDisplaySleep()
            let snapshot = saved
            hardwareQueue.async {
                let failures = self.hardware.restore(snapshot)
                DispatchQueue.main.async {
                    if failures.isEmpty { self.removeSnapshot() }
                    NSApp.terminate(nil)
                }
            }
        } else if transitioning {
            hardwareQueue.async { DispatchQueue.main.async { NSApp.terminate(nil) } }
        } else {
            NSApp.terminate(nil)
        }
    }
}

private let app = NSApplication.shared
private let hardware = DisplayHardware()
if CommandLine.arguments.contains("--restore") {
    let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BlackoutMenubar/brightness.json")
    if let data = try? Data(contentsOf: file),
       let snapshot = try? JSONDecoder().decode([SavedDisplay].self, from: data) {
        let failures = hardware.restore(snapshot)
        if failures.isEmpty {
            try? FileManager.default.removeItem(at: file)
            print("brightness restored")
        } else {
            fputs("failed to restore displays: \(failures)\n", stderr)
            exit(1)
        }
    } else { print("no saved brightness") }
} else if CommandLine.arguments.contains("--diagnose") {
    for display in hardware.capture() {
        let kind = display.isBuiltIn ? "built-in" : "external"
        print("display \(display.id) \(kind): \(display.brightness) / \(display.maximum.map(String.init) ?? "1")")
    }
} else {
    let delegate = BlackoutApp()
    app.delegate = delegate
    app.run()
}
