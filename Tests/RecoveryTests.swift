import Foundation
import Testing
@testable import BlackoutCore

private func record(_ id: UInt32, uuid: String? = nil, level: Double = 70) -> SavedDisplay {
    SavedDisplay(id: id, uuid: uuid, brightness: level, maximum: 100, isBuiltIn: false)
}

private func temporaryStore() throws -> RecoveryStore {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BlackoutTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return RecoveryStore(url: folder.appendingPathComponent("brightness.json"))
}

@Test func failedOrDisconnectedDisplaySurvivesPartialRestore() throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let first = record(1, uuid: "first"), second = record(3, uuid: "second")
    try store.save([first, second])
    let remaining = try store.restore { $0.key == "first" }
    #expect(remaining == [second])
    #expect(try store.load() == [second])
    var retried: [String] = []
    _ = try store.restore { retried.append($0.key); return true }
    #expect(retried == ["second"])
    #expect(!store.exists)
}

@Test func reconnectUsesUUIDInsteadOfRecycledNumericID() {
    let display = record(3, uuid: "dell")
    #expect(display.matches(id: 9, uuid: "dell", isBuiltIn: false))
    #expect(!display.matches(id: 3, uuid: "other-monitor", isBuiltIn: false))
    #expect(!display.matches(id: 3, uuid: "dell", isBuiltIn: true))
}

@Test func legacySnapshotRemainsReadable() throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    try Data(#"[{"id":3,"brightness":70,"maximum":100,"isBuiltIn":false}]"#.utf8).write(to: store.url)
    let saved = try #require(store.load().first)
    #expect(saved.uuid == nil)
    #expect(saved.matches(id: 3, uuid: "dell", isBuiltIn: false))
    #expect(!saved.matches(id: 9, uuid: "dell", isBuiltIn: false))
}

@Test(arguments: ["invalid json", #"[{"id":3,"brightness":-1,"maximum":100,"isBuiltIn":false}]"#])
func corruptJournalIsPreservedAndNeverSentToHardware(contents: String) throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let data = Data(contents.utf8)
    try data.write(to: store.url)
    var writes = 0
    #expect(throws: (any Error).self) {
        _ = try store.restore { _ in writes += 1; return true }
    }
    #expect(writes == 0)
    #expect(try Data(contentsOf: store.url) == data)
}

@Test func writeAcknowledgementWithUnchangedReadbackIsFailure() {
    var attempts = 0
    let result = BrightnessConfirmation.verify(target: 25, builtIn: false, read: {
        attempts += 1; return record(3, level: 70)
    }, pause: { _ in })
    #expect(!result.confirmed)
    #expect(result.actual?.brightness == 70)
    #expect(attempts == 3)
}

@Test func slowReadbackAndUnreadableDisplay() {
    var attempts = 0
    let delayed = BrightnessConfirmation.verify(target: 25, builtIn: false, read: {
        attempts += 1; return record(3, level: attempts == 3 ? 25 : 70)
    }, pause: { _ in })
    #expect(delayed.confirmed)
    let missing = BrightnessConfirmation.verify(target: 25, builtIn: false, read: { nil }, pause: { _ in })
    #expect(!missing.confirmed)
    #expect(missing.actual == nil)
}
