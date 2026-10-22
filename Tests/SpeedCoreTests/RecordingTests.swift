import XCTest
@testable import SpeedCore

final class RecordingTests: XCTestCase {
    func testReportedAccuracyFloorIsNotObservedSpeedError() throws {
        var engine = SpeedEstimator()
        for i in 0...300 {
            let time = Double(i)
            engine.ingest(SpeedObservation(timestamp: time, speed: 20, speedAccuracy: 2.8, horizontalAccuracy: 5), receivedAt: time)
        }
        let estimate = engine.estimate(at: 300)
        XCTAssertEqual(try XCTUnwrap(estimate.speed), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(estimate.uncertainty) * 3.6, 10.08, accuracy: 1e-9)
        let diagnostics = engine.diagnostics(at: 300)
        XCTAssertLessThan(try XCTUnwrap(diagnostics.covarianceSpeedSigma), 2.8)
        XCTAssertEqual(diagnostics.uncertaintyFloor, 2.8)
    }
    private func estimate(_ t: Double, _ speed: Double?) -> SpeedEstimate {
        SpeedEstimate(timestamp: t, speed: speed, uncertainty: speed == nil ? nil : 1,
                      state: speed == nil ? .unavailable : .measured,
                      source: speed == nil ? .none : .location, observationAge: 0)
    }

    func testDistanceUsesTrapezoidsAndNeverBridgesUnavailableOrLongGaps() {
        var distance = DistanceAccumulator()
        distance.ingest(estimate(0, 0))
        distance.ingest(estimate(1, 10))
        XCTAssertEqual(distance.meters, 5, accuracy: 1e-9)
        distance.ingest(estimate(1.2, nil))
        distance.ingest(estimate(1.4, 20))
        distance.ingest(estimate(1.6, 20))
        XCTAssertEqual(distance.meters, 9, accuracy: 1e-9)
        distance.ingest(estimate(10, 20))
        XCTAssertEqual(distance.meters, 9, accuracy: 1e-9)
        XCTAssertEqual(distance.coveredSeconds, 1.2, accuracy: 1e-9)
    }

    func testDuplicateAndReversedTimestampsDoNotAddOrRewindDistance() {
        var distance = DistanceAccumulator()
        distance.ingest(estimate(0, 10))
        distance.ingest(estimate(1, 10))
        distance.ingest(estimate(0.5, 100))
        distance.ingest(estimate(1, 10))
        distance.ingest(estimate(2, 10))
        XCTAssertEqual(distance.meters, 20, accuracy: 1e-9)
    }

    func testHandheldMotionPreservesMeasurementTimeSeparateFromReceipt() throws {
        let motion = RawMotion(acceleration: [0, 0, 0], gravity: [0, 0, -1],
                               rotationRate: [0, 0, 0], quaternion: [0, 0, 0, 1], timestamp: 3.75)
        let event = ReplayEvent(receivedAt: 4, rawMotion: motion,
                                marker: RecordingMarker(id: "M001", kind: "arrival", note: "A"))
        let decoded = try ReplayEvent.decode(JSONEncoder().encode(event))
        XCTAssertEqual(decoded.rawMotion?.timestamp, 3.75)
        XCTAssertEqual(decoded.receivedAt, 4)
        XCTAssertEqual(decoded.marker?.note, "A")
        var replay = SpeedReplay()
        XCTAssertNil(try replay.consume(decoded).estimate.speed)
    }

    func testJournalPersistsOrderedEventsAndClosesBeforeExport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try SensorJournal(url: url)
        for i in 0..<100 { journal.append(ReplayEvent(receivedAt: Double(i))) }
        try await journal.finish()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        XCTAssertEqual(try lines.map { try ReplayEvent.decode(Data($0.utf8)).receivedAt }, (0..<100).map(Double.init))
        XCTAssertThrowsError(try SensorJournal(url: url)) // never append a second session over an existing file
    }

    func testJournalFlushesLargeBatchesAndIdleTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try SensorJournal(url: url)
        var marker = ReplayEvent(receivedAt: 0)
        marker.sensorError = String(repeating: "x", count: 1000)
        for i in 0..<100 { marker.receivedAt = Double(i); journal.append(marker) }
        journal.append(ReplayEvent(receivedAt: 100))
        // >64 KB went out immediately; the small tail waits for the idle flush.
        try await Task.sleep(for: .milliseconds(300))
        let early = try Data(contentsOf: url).count
        XCTAssertGreaterThanOrEqual(early, SensorJournal.flushBytes)
        try await Task.sleep(for: .seconds(SensorJournal.flushInterval + 0.5))
        let idle = try Data(contentsOf: url)
        XCTAssertGreaterThan(idle.count, early)
        XCTAssertEqual(idle.split(separator: 10).count, 101)
        try await journal.finish()
        XCTAssertEqual(try Data(contentsOf: url), idle)
    }

    func testQuantizedMotionIsShortAndClose() throws {
        let raw = RawMotion(acceleration: [0.012345678912345, -0.98765432109876, 1e-9],
                            gravity: [0.1, -0.2, -0.97467943448089], rotationRate: [0.333333333333, 0, -0.5],
                            quaternion: [0.70710678118654, 0, 0, 0.70710678118654], timestamp: 12.3456789)
        let q = raw.quantized()
        for (a, b) in zip(raw.acceleration + raw.rotationRate, q.acceleration + q.rotationRate) { XCTAssertEqual(a, b, accuracy: 5e-6) }
        XCTAssertEqual(q.timestamp, raw.timestamp)
        let json = String(decoding: try JSONEncoder().encode(q), as: UTF8.self)
        XCTAssertTrue(json.contains("0.01235") && json.contains("0.707107") && !json.contains("0.0123456"), json)
        XCTAssertLessThan(json.count + 40, String(decoding: try JSONEncoder().encode(raw), as: UTF8.self).count)
    }
}
