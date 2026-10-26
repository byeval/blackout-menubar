import Foundation
import CoreGraphics
import ColorSync
import Darwin

final class DisplayHardware {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private let library: UnsafeMutableRawPointer?
    private let getter: GetBrightness?
    private let setter: SetBrightness?
    private let ddcURL: URL

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        if let library, let get = dlsym(library, "DisplayServicesGetBrightness"),
           let set = dlsym(library, "DisplayServicesSetBrightness") {
            getter = unsafeBitCast(get, to: GetBrightness.self)
            setter = unsafeBitCast(set, to: SetBrightness.self)
        } else { getter = nil; setter = nil }
        ddcURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/m1ddc")
    }

    func onlineIDs() -> [UInt32] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func uuid(_ id: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    func resolve(_ display: SavedDisplay) -> UInt32? {
        let candidates = onlineIDs().filter {
            display.matches(id: $0, uuid: uuid($0), isBuiltIn: CGDisplayIsBuiltin($0) != 0)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func read(_ id: UInt32) -> SavedDisplay? {
        guard onlineIDs().contains(id), let identity = uuid(id) else { return nil }
        let builtIn = CGDisplayIsBuiltin(id) != 0
        let value: Double
        let maximum: Int?
        if builtIn {
            var result: Float = 0
            guard let getter, getter(id, &result) == 0, result.isFinite,
                  (0...1).contains(result) else { return nil }
            value = Double(result)
            maximum = nil
        } else {
            guard let current = Int(runDDC(["display", "id=\(id)", "get", "luminance"]) ?? ""),
                  let maxValue = Int(runDDC(["display", "id=\(id)", "max", "luminance"]) ?? ""),
                  maxValue > 0, (0...maxValue).contains(current) else { return nil }
            value = Double(current)
            maximum = maxValue
        }
        return SavedDisplay(id: id, uuid: identity, brightness: value, maximum: maximum, isBuiltIn: builtIn)
    }

    func capture() -> [SavedDisplay] { onlineIDs().compactMap { read($0) } }

    func set(_ display: SavedDisplay, percent: Double) -> BrightnessResult {
        // Leave full black to the explicit blackout action so the menu stays usable.
        let level = min(100, max(1, percent))
        let raw = display.isBuiltIn ? level / 100 :
            max(1, (Double(display.maximum ?? 100) * level / 100).rounded())
        return write(display, raw: raw)
    }

    func restore(_ display: SavedDisplay) -> BrightnessResult { write(display, raw: display.brightness) }

    private func write(_ display: SavedDisplay, raw: Double) -> BrightnessResult {
        guard let id = resolve(display) else {
            return BrightnessResult(actual: nil, error: "显示器已断开，连接后可重试")
        }
        let succeeded: Bool
        if display.isBuiltIn { succeeded = setter?(id, Float(raw)) == 0 }
        else { succeeded = runDDC(["display", "id=\(id)", "set", "luminance", "\(Int(raw))"]) != nil }
        guard succeeded else {
            return BrightnessResult(actual: read(id), error: "硬件调光失败，请检查连接与 DDC/CI")
        }
        return BrightnessConfirmation.verify(target: raw, builtIn: display.isBuiltIn,
            read: { self.read(id) }, pause: { attempt in
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.06 : 0.15)
            })
    }

    private func runDDC(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: ddcURL.path) else { return nil }
        let task = Process()
        task.executableURL = ddcURL
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do {
            try task.run()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                task.terminate()
                if finished.wait(timeout: .now() + 0.2) == .timedOut {
                    kill(task.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 0.2)
                }
                return nil
            }
            guard task.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.contains("DDC communication failure") ? nil : result
        } catch { return nil }
    }
}
