import AppKit
import Carbon
import CoreGraphics
import IOKit.pwr_mgt
import os

private let log = Logger(subsystem: "com.byeval.blackout", category: "brightness")

private final class BrightnessRow: NSView {
    let slider = NSSlider(value: 50, minValue: 1, maxValue: 100, target: nil, action: nil)
    let valueLabel = NSTextField(labelWithString: "—")
    let detail = NSTextField(labelWithString: "正在读取硬件亮度…")
    var record: SavedDisplay?
    var changed: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    init(name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 16, y: 10, width: 232, height: 18)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 248, y: 10, width: 56, height: 18)
        slider.frame = NSRect(x: 14, y: 32, width: 292, height: 24)
        slider.isContinuous = true
        slider.isEnabled = false
        slider.target = self
        slider.action = #selector(adjust)
        slider.setAccessibilityLabel("\(name)亮度")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 16, y: 64, width: 288, height: 18)
        for view in [title, valueLabel, slider, detail] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func adjust() {
        let percent = slider.integerValue
        valueLabel.stringValue = "\(percent)%"
        showStatus("正在调整到 \(percent)%…")
        changed?(percent)
    }
    func showStatus(_ text: String, error: Bool = false) {
        detail.stringValue = text
        detail.textColor = error ? .systemOrange : .secondaryLabelColor
        detail.toolTip = text
        slider.setAccessibilityHelp(text)
    }
    func showActual(_ record: SavedDisplay) {
        self.record = record
        slider.doubleValue = record.percent
        valueLabel.stringValue = "\(Int(record.percent.rounded()))%"
    }
}

private final class BlackWindow: NSWindow {
    var restoreAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func mouseDown(with event: NSEvent) { restoreAction?() }
    override func keyDown(with event: NSEvent) { restoreAction?() }
}

private final class BlackoutApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Mode { case idle, entering, active, restoring }
    private let hardware = DisplayHardware()
    // Blocking hardware I/O is serial: restoration always follows pending writes.
    // All UI and session state belongs to the main thread.
    private let hardwareQueue = DispatchQueue(label: "blackout.hardware", qos: .userInitiated)
    private let store = RecoveryStore.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var mode = Mode.idle
    private var rows: [UInt32: BrightnessRow] = [:]
    private var pending: [String: (SavedDisplay, Int)] = [:]
    private var writing = false
    private var refreshing = false
    private var generation = 0
    private var windows: [BlackWindow] = []
    private var saved: [SavedDisplay] = []
    private var reconciling = false
    private var assertionID = IOPMAssertionID(0)
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var message: String?
    private var hotKeyWarning: String?
    private var quitRequested = false
    private var startRequested = false
    private var demoSeconds: Double?
    private var enterItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var lowPercent: Int {
        let value = UserDefaults.standard.integer(forKey: "lowPercent")
        return [1, 5, 10, 20].contains(value) ? value : 5
    }
    private var busy: Bool { writing || !pending.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Blackout · 屏幕亮度")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Blackout · 屏幕亮度与黑屏"
        if UserDefaults.standard.object(forKey: "lowPercent") == nil,
           let old = UserDefaults.standard.persistentDomain(forName: "local.xuhong.blackout")?["lowPercent"] as? Int,
           [1, 5, 10, 20].contains(old) {
            UserDefaults.standard.set(old, forKey: "lowPercent")
        }
        installHotKey()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-seconds=") }),
           let seconds = Double(arg.dropFirst("--demo-seconds=".count)), seconds > 0 { demoSeconds = seconds }
        startRequested = CommandLine.arguments.contains("--start-blackout") || demoSeconds != nil
        rebuildMenu()
        if store.exists { retryRestore(nil) } else { finishStartup() }
    }
    private func finishStartup() {
        if quitRequested { NSApp.terminate(nil); return }
        if startRequested && !store.exists {
            startRequested = false
            enterBlackout(nil)
        } else { startRequested = false; refreshReadings() }
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
        let registrationStatus = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey | controlKey),
            id, GetApplicationEventTarget(), 0, &hotKey)
        if handlerStatus != noErr || registrationStatus != noErr { hotKeyWarning = "快捷键不可用；点击黑屏仍可恢复" }
    }
    private func toggle() {
        if mode == .active || mode == .entering { restoreDisplay(nil) } else { enterBlackout(nil) }
    }
    @discardableResult
    private func addAction(_ title: String, _ action: Selector, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; menu.addItem(item)
        return item
    }
    private func addHint(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false; menu.addItem(item)
    }
    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false; menu.delegate = self
        rows = [:]
        addHint("屏幕亮度 · 拖动立即调整", to: menu)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let row = BrightnessRow(name: screen.localizedName)
            row.changed = { [weak self, weak row] percent in
                guard let self, let record = row?.record, self.mode == .idle, !self.store.exists else { return }
                self.generation += 1
                self.pending[record.key] = (record, percent)
                self.pumpWrites()
            }
            rows[id] = row
            let item = NSMenuItem(); item.view = row; menu.addItem(item)
        }
        if rows.isEmpty { addHint("没有可用显示器", to: menu) }
        refreshItem = addAction("重新读取亮度", #selector(refreshAction), to: menu, enabled: mode == .idle && !busy)
        menu.addItem(.separator())
        enterItem = addAction("进入黑屏低亮度", #selector(enterBlackout(_:)), to: menu,
            enabled: mode == .idle && !busy && !store.exists && !rows.isEmpty)
        addAction("恢复显示与原亮度", #selector(restoreDisplay(_:)), to: menu, enabled: mode == .active || mode == .entering)
        if store.exists && mode == .idle {
            addAction("重试恢复未完成的屏幕", #selector(retryRestore(_:)), to: menu, enabled: !busy)
        }
        let settings = NSMenuItem(title: "黑屏目标亮度：\(lowPercent)%", action: nil, keyEquivalent: "")
        let levels = NSMenu(); levels.autoenablesItems = false
        addHint("仅下次进入黑屏时生效", to: levels)
        for percent in [1, 5, 10, 20] {
            let item = addAction("\(percent)%", #selector(selectBlackoutBrightness(_:)), to: levels, enabled: mode == .idle)
            item.tag = percent; item.state = percent == lowPercent ? .on : .off
        }
        settings.submenu = levels; menu.addItem(settings)
        addHint("点击黑屏或按 ⌃⌥⌘B 恢复", to: menu)
        if let message { addHint(message, to: menu) }
        if let hotKeyWarning { addHint(hotKeyWarning, to: menu) }
        menu.addItem(.separator())
        addAction("退出 Blackout", #selector(quit(_:)), to: menu)
        statusItem.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { refreshReadings() }
    @objc private func refreshAction() { refreshReadings() }
    private func refreshReadings() {
        guard mode == .idle, !busy, !refreshing else { return }
        refreshing = true
        let token = generation
        hardwareQueue.async {
            let readings = self.hardware.capture()
            DispatchQueue.main.async {
                self.refreshing = false
                guard self.mode == .idle else { return }
                guard self.generation == token else {
                    if !self.busy { self.refreshReadings() }
                    return
                }
                for (id, row) in self.rows {
                    if let record = readings.first(where: { $0.id == id }) {
                        row.showActual(record)
                        row.slider.isEnabled = !self.store.exists && !self.quitRequested
                        row.showStatus(self.store.exists ? "请先恢复上次的亮度" :
                            (record.isBuiltIn ? "硬件亮度 · 已读取" : "DDC 硬件亮度 · 已读取"))
                    } else {
                        row.record = nil; row.slider.isEnabled = false; row.valueLabel.stringValue = "—"
                        row.showStatus("硬件亮度不可用 · 仍可使用黑屏", error: true)
                    }
                }
            }
        }
    }
    private func updateAvailability() {
        enterItem?.isEnabled = mode == .idle && !busy && !store.exists && !rows.isEmpty && !quitRequested
        refreshItem?.isEnabled = mode == .idle && !busy && !quitRequested
    }
    private func pumpWrites() {
        updateAvailability()
        guard !writing, let (record, percent) = pending.values.first else { return }
        pending.removeValue(forKey: record.key); writing = true
        hardwareQueue.async {
            let result = self.hardware.set(record, percent: Double(percent))
            DispatchQueue.main.async {
                self.writing = false
                let row = self.rows.values.first { $0.record?.key == record.key }
                if self.pending[record.key] == nil {
                    if let actual = result.actual { row?.showActual(actual) } else { row?.valueLabel.stringValue = "—" }
                    row?.showStatus(result.error ?? "硬件亮度 · 已确认", error: !result.confirmed)
                }
                if let error = result.error { log.error("Brightness change failed: \(error, privacy: .public)") }
                self.updateAvailability()
                if !self.pending.isEmpty { self.pumpWrites() }
                else if self.quitRequested { NSApp.terminate(nil) }
                else if self.rows.values.contains(where: { $0.record == nil }) { self.refreshReadings() }
            }
        }
    }
    @objc private func selectBlackoutBrightness(_ sender: NSMenuItem) {
        guard mode == .idle, !busy else { return }
        UserDefaults.standard.set(sender.tag, forKey: "lowPercent")
        rebuildMenu(); refreshReadings()
    }
    @objc private func enterBlackout(_ sender: Any?) {
        guard mode == .idle, !busy, !store.exists, !rows.isEmpty else { return }
        generation += 1; mode = .entering; message = "正在保存原亮度…"; rebuildMenu()
        let percent = lowPercent
        hardwareQueue.async {
            let snapshot = self.hardware.capture()
            DispatchQueue.main.async {
                // Restoring/quitting during capture cancels entry before any writes.
                guard self.mode == .entering else { return }
                do { try self.store.save(snapshot) }
                catch {
                    self.mode = .idle; self.message = "无法保存原亮度，未进入黑屏"
                    self.rebuildMenu(); self.finishStartup(); return
                }
                self.saved = snapshot; self.showWindows(); self.preventDisplaySleep()
                self.hardwareQueue.async {
                    let results = snapshot.map { self.hardware.set($0, percent: Double(percent)) }
                    DispatchQueue.main.async {
                        guard self.mode == .entering else { return }
                        self.mode = .active
                        let unsupported = snapshot.count < self.rows.count
                        self.message = results.allSatisfy(\.confirmed) && !unsupported ?
                            "黑屏中 · 硬件亮度已确认" : "部分屏幕仅用遮罩，硬件调光未确认"
                        self.rebuildMenu()
                        if let seconds = self.demoSeconds {
                            self.demoSeconds = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.restoreDisplay(nil) }
                        }
                        self.reconcileBlackout()
                    }
                }
            }
        }
    }
    @objc private func restoreDisplay(_ sender: Any?) {
        guard mode == .active || mode == .entering else { return }
        hideWindows(); allowDisplaySleep(); beginRestore()
    }
    @objc private func retryRestore(_ sender: Any?) {
        guard mode == .idle, !busy else { return }
        beginRestore()
    }
    private func beginRestore() {
        generation += 1; mode = .restoring; message = "正在恢复并确认原亮度…"; rebuildMenu()
        hardwareQueue.async {
            let result: Result<[SavedDisplay], Error> = Result {
                try self.store.restore { self.hardware.restore($0).confirmed }
            }
            DispatchQueue.main.async {
                self.mode = .idle; self.saved = []
                switch result {
                case .success(let remaining):
                    self.message = remaining.isEmpty ? "原亮度已恢复并确认" : "仍有 \(remaining.count) 块屏幕待恢复，记录已保留"
                case .failure: self.message = "恢复记录无法读取或更新，已保留，请检查"
                }
                self.rebuildMenu(); self.finishStartup()
            }
        }
    }
    private func showWindows() {
        hideWindows(); NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            // Global screen.frame must not be offset by passing screen: again.
            let window = BlackWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black; window.isOpaque = true; window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.restoreAction = { [weak self] in self?.restoreDisplay(nil) }
            window.orderFrontRegardless(); window.makeKey(); windows.append(window)
        }
    }
    private func hideWindows() { windows.forEach { $0.orderOut(nil) }; windows.removeAll() }
    @objc private func displaysChanged() {
        generation += 1
        if mode == .active || (mode == .entering && !windows.isEmpty) {
            showWindows()
            if mode == .active { reconcileBlackout() }
        } else if mode == .idle {
            rebuildMenu()
            if store.exists && !busy { retryRestore(nil) } else { refreshReadings() }
        }
    }
    private func reconcileBlackout() {
        guard mode == .active, !reconciling else { return }
        reconciling = true
        let original = saved, percent = lowPercent
        hardwareQueue.async {
            let connected = self.hardware.capture()
            DispatchQueue.main.async {
                self.reconciling = false
                guard self.mode == .active else { return }
                let added = connected.filter { item in !original.contains { $0.key == item.key } }
                let merged = original + added
                do { try self.store.save(merged) }
                catch {
                    self.message = "新屏幕仅用遮罩：原亮度无法保存"; self.rebuildMenu(); return
                }
                self.saved = merged
                // Reconnected displays keep the original snapshot, not a dim reading.
                self.hardwareQueue.async {
                    let results = connected.map { self.hardware.set($0, percent: Double(percent)) }
                    DispatchQueue.main.async {
                        guard self.mode == .active else { return }
                        if !results.allSatisfy(\.confirmed) {
                            self.message = "部分屏幕硬件调光未确认，恢复记录已保留"; self.rebuildMenu()
                        }
                    }
                }
            }
        }
    }
    private func preventDisplaySleep() {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Blackout keeps displays on" as CFString, &assertionID)
        if result != kIOReturnSuccess { log.error("Display sleep assertion failed: \(result)") }
    }
    private func allowDisplaySleep() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitRequested && mode == .idle && !busy { return .terminateNow }
        quitRequested = true; startRequested = false
        if mode == .active || mode == .entering { restoreDisplay(nil); return .terminateCancel }
        if mode == .restoring || busy {
            rows.values.forEach { $0.slider.isEnabled = false }; updateAvailability()
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main
private enum BlackoutMain {
    static func main() {
        let app = NSApplication.shared
        let hardware = DisplayHardware(), store = RecoveryStore.standard
        // Diagnose is read-only. Every writer, including CLI recovery, takes the
        // same process lock so two launches cannot overwrite the recovery journal.
        let isDiagnosis = CommandLine.arguments.contains("--diagnose")
        let identifiers = Set(["local.xuhong.blackout", "com.byeval.blackout"])
        if !isDiagnosis {
            let other = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && identifiers.contains($0.bundleIdentifier ?? "")
            }
            if other != nil {
                fputs("Blackout is already running; quit it before starting another copy or CLI recovery\n", stderr)
                exit(1)
            }
        }
        var lockFD: Int32 = -1
        if !isDiagnosis {
            do {
                try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch { fputs("cannot open recovery directory\n", stderr); exit(1) }
            lockFD = open(store.url.deletingLastPathComponent().appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                fputs("another Blackout process owns the hardware session\n", stderr); exit(1)
            }
        }
        defer { if lockFD >= 0 { close(lockFD) } }
        if CommandLine.arguments.contains("--diagnose") {
            for id in hardware.onlineIDs() {
                if let record = hardware.read(id) {
                    print("display \(id) \(record.isBuiltIn ? "built-in" : "external"): \(record.brightness) / \(record.maximum.map(String.init) ?? "1") uuid=\(record.uuid ?? "unknown")")
                } else { print("display \(id): hardware brightness unavailable") }
            }
        } else if CommandLine.arguments.contains("--restore") {
            do {
                let remaining = try store.restore { hardware.restore($0).confirmed }
                guard remaining.isEmpty else {
                    fputs("restoration unconfirmed for \(remaining.count) displays; snapshot retained\n", stderr); exit(1)
                }
                print("brightness restored and verified")
            } catch { fputs("recovery record could not be read or updated; retained\n", stderr); exit(1) }
        } else if CommandLine.arguments.contains("--verify-brightness") {
            guard !store.exists else { fputs("restore the existing snapshot before testing\n", stderr); exit(1) }
            do {
                let original = hardware.capture()
                guard !original.isEmpty else { fputs("no controllable displays\n", stderr); exit(1) }
                try store.save(original)
                var passed = true
                for record in original {
                    let target = record.percent >= 15 ? record.percent - 5 : record.percent + 5
                    let result = hardware.set(record, percent: target)
                    passed = passed && result.confirmed
                    print("display \(record.id): \(record.percent)% -> \(target)%, readback \(result.actual?.percent.description ?? "unavailable")%, confirmed=\(result.confirmed)")
                }
                let remaining = try store.restore { record in
                    let result = hardware.restore(record)
                    print("display \(record.id): restore \(record.percent)%, confirmed=\(result.confirmed)")
                    return result.confirmed
                }
                if !passed || !remaining.isEmpty { exit(1) }
            } catch { fputs("verification failed; inspect recovery journal\n", stderr); exit(1) }
        } else {
            let delegate = BlackoutApp(); app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
