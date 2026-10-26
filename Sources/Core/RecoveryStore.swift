import Foundation

// Optional UUID keeps the 1.0 snapshot format readable. New snapshots always use
// the stable display UUID; numeric display IDs can change after reconnecting.
struct SavedDisplay: Codable, Equatable {
    let id: UInt32
    let uuid: String?
    let brightness: Double
    let maximum: Int?
    let isBuiltIn: Bool

    var key: String { uuid ?? "legacy-\(id)" }
    var percent: Double { brightness / Double(maximum ?? 1) * 100 }

    func matches(id: UInt32, uuid: String?, isBuiltIn: Bool) -> Bool {
        guard self.isBuiltIn == isBuiltIn else { return false }
        if let savedUUID = self.uuid { return savedUUID == uuid }
        return self.id == id
    }
}

struct RecoveryStore {
    let url: URL

    static var standard: RecoveryStore {
        RecoveryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackoutMenubar/brightness.json"))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() throws -> [SavedDisplay] {
        guard exists else { return [] }
        let records = try JSONDecoder().decode([SavedDisplay].self, from: Data(contentsOf: url))
        try validate(records)
        return records
    }

    private func validate(_ records: [SavedDisplay]) throws {
        guard records.allSatisfy({
            $0.brightness.isFinite && $0.brightness >= 0 &&
            ($0.isBuiltIn ? $0.maximum == nil && $0.brightness <= 1 :
                ($0.maximum ?? 0) > 0 && $0.brightness <= Double($0.maximum ?? 0))
        }), Set(records.map(\.key)).count == records.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func save(_ records: [SavedDisplay]) throws {
        try validate(records)
        if records.isEmpty {
            if exists { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        }
    }

    // Successful displays disappear from the journal individually. A disconnected
    // or unconfirmed display stays recoverable without overwriting later edits.
    func restore(using write: (SavedDisplay) -> Bool) throws -> [SavedDisplay] {
        var remaining = try load()
        for display in remaining {
            if write(display) {
                remaining.removeAll { $0.key == display.key }
                try save(remaining)
            }
        }
        // Remove an empty legacy journal too.
        try save(remaining)
        return remaining
    }
}

struct BrightnessResult {
    let actual: SavedDisplay?
    let error: String?
    var confirmed: Bool { error == nil }
}

enum BrightnessConfirmation {
    // A write acknowledgement alone is not proof. Retry reads for slow monitors.
    static func verify(target: Double, builtIn: Bool,
                       read: () -> SavedDisplay?, pause: (Int) -> Void) -> BrightnessResult {
        var actual: SavedDisplay?
        for attempt in 0..<3 {
            pause(attempt)
            actual = read()
            if let actual, abs(actual.brightness - target) <= (builtIn ? 0.006 : 0.01) {
                return BrightnessResult(actual: actual, error: nil)
            }
        }
        return BrightnessResult(actual: actual,
            error: actual == nil ? "无法读回亮度，请检查连接" : "亮度未达到目标，请重试")
    }
}
