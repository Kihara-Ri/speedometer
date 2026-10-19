import XCTest
@testable import SpeedCore

final class RecordingStoreTests: XCTestCase {
    func testTitleReferencesAndRawFileSurviveTrashAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("session-example.jsonl")
        let raw = Data("{\"receivedAt\":0}\n".utf8)
        try raw.write(to: url)
        let store = RecordingStore(directory: root)
        var info = RecordingInfo()
        info.title = "A 到 B"
        info.note = "手持靠窗"
        info.references = [DistanceReference(startMarker: "M1", endMarker: "M2", meters: 1200, source: "铁路里程")]
        try store.save(info, for: url)
        XCTAssertEqual(try store.entries().first?.info.title, "A 到 B")
        try store.moveToTrash(url)
        XCTAssertTrue(try store.entries().isEmpty)
        let deleted = try XCTUnwrap(store.entries(deleted: true).first)
        XCTAssertEqual(deleted.info.references.first?.meters, 1200)
        try store.restore(deleted.url)
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertEqual(try store.info(for: url).note, "手持靠窗")
    }

    func testRestoreNeverOverwritesAnExistingRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecordingStore(directory: root)
        let url = root.appendingPathComponent("session.jsonl")
        try Data("old".utf8).write(to: url)
        try store.moveToTrash(url)
        try Data("new".utf8).write(to: url)
        XCTAssertThrowsError(try store.restore(store.entries(deleted: true)[0].url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    }
}
