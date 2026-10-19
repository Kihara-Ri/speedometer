import XCTest
@testable import SpeedCore

final class SessionReportTests: XCTestCase {
    func testConfirmedArrivalUsesStopTimeAndReportRetainsPredictionAndFeedback() throws {
        var departure = event(0, 10)
        departure.marker = RecordingMarker(id: "M1", kind: "departure", note: "A")
        var arrival = event(10, 0)
        arrival.marker = RecordingMarker(id: "M2", kind: "arrival", note: "确认到站", timestamp: 1)
        arrival.railCandidate = RailArrivalCandidate(id: "R1", algorithmID: "test", evidenceStartedAt: 0,
            stoppedAt: 1, detectedAt: 5, peakSpeed: 12, brakingSeconds: 8, completedRuns: 2)
        arrival.railResolution = RailArrivalResolution(candidateID: "R1", timestamp: 10, stoppedAt: 1,
            answer: .confirmed, reason: .responded)
        let report = try load([departure, event(1, 0), arrival])
        XCTAssertEqual(report.markers.last?.timestamp, 1)
        XCTAssertEqual(report.stationSegments.first?.distance.duration, 1)
        XCTAssertEqual(report.railCandidates.first?.id, "R1")
        XCTAssertEqual(report.railResolutions.first?.answer, .confirmed)
    }
    func testCSVExportsMissingSpeedAsEmptyAndRetainsSIUnits() throws {
        let report = try load([event(0, nil), event(1, 10), event(2, 10)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try report.writeCSV(to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        let missing = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        let valid = lines[2].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(missing[2], "")
        XCTAssertEqual(valid[2], "10.0")
    }
    private func event(_ t: Double, _ speed: Double?) -> ReplayEvent {
        var event = ReplayEvent(receivedAt: t)
        event.recordedEstimate = SpeedEstimate(timestamp: t, speed: speed, uncertainty: speed == nil ? nil : 1,
            state: speed == nil ? .unavailable : .measured, source: speed == nil ? .none : .location, observationAge: 0)
        return event
    }

    private func load(_ events: [ReplayEvent], tail: String = "") throws -> SessionReport {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        let text = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined() + tail
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try SessionReport.load(url: url)
    }

    func testRecordedDistanceClipsIntervalAndReportsGapsWithoutInventingFullDistance() throws {
        let report = try load([event(0, 0), event(1, 10), event(2, nil), event(3, 20), event(4, 20)])
        XCTAssertEqual(report.distance.meters, 25, accuracy: 1e-9)
        XCTAssertEqual(report.distance.coveredSeconds, 2, accuracy: 1e-9)
        XCTAssertFalse(report.distance.isComplete)
        XCTAssertEqual(report.distance.longestGap, 2, accuracy: 1e-9)
        let interval = report.distance(from: 0.25, to: 0.75)
        XCTAssertEqual(interval.meters, 2.5, accuracy: 1e-9)
        XCTAssertTrue(interval.isComplete)
    }

    func testLegacyLogsReplayAndBrokenTailIsReportedInsteadOfLosingTheRecord() throws {
        let report = try load((0...3).map { t in
            ReplayEvent(receivedAt: Double(t), speed: SpeedObservation(timestamp: Double(t), speed: 10,
                speedAccuracy: 0.5, horizontalAccuracy: 5))
        }, tail: "{\"receivedAt\":")
        XCTAssertEqual(report.samples.last?.speed, 10)
        XCTAssertEqual(report.malformedLines, 1)
        XCTAssertFalse(report.endedNormally)
        XCTAssertEqual(report.sensorStats["location"]?.count, 4)
    }

    func testStationIntervalsUseMarkersAndDetailRetainsDiagnosticAndMotionValues() throws {
        var first = event(0, 10)
        first.marker = RecordingMarker(id: "M1", kind: "departure", note: "A")
        var raw = ReplayEvent(receivedAt: 0.5, rawMotion: RawMotion(acceleration: [1,2,3], gravity: [0,0,-1],
            rotationRate: [0,0,0], quaternion: [0,0,0,1], timestamp: 0.45))
        raw.gyroscope = VectorSample(timestamp: 0.4, values: [0.1,0.2,0.3])
        var last = event(1, 10)
        last.marker = RecordingMarker(id: "M2", kind: "arrival", note: "B")
        last.diagnostics = FilterDiagnostics(stateTime: 1, state: [10,0.2,0.1], covariance: nil,
            lastResult: .accepted, innovation: 0.1, nis: 0.2, reportedSpeedAccuracy: 1,
            uncertaintyFloor: 1, covarianceSpeedSigma: 0.5)
        let report = try load([first, raw, last])
        XCTAssertEqual(report.stationSegments.count, 1)
        XCTAssertEqual(report.stationSegments[0].distance.meters, 10, accuracy: 1e-9)
        let point = try XCTUnwrap(report.nearestSample(to: 0.9))
        XCTAssertEqual(point.motion?.timestamp, 0.45)
        XCTAssertEqual(point.gyroscope?.values, [0.1,0.2,0.3])
        XCTAssertEqual(point.diagnostics?.state?[1], 0.2)
    }

    func testPlotReductionPreservesBriefSpeedPeakAndGapGroups() throws {
        var events = (0...1000).map { event(Double($0)/10, $0 == 333 ? 80 : 10) }
        events[500] = event(50, nil)
        let report = try load(events)
        let plot = report.plotSamples(limit: 100)
        XCTAssertLessThanOrEqual(plot.count, 120)
        XCTAssertTrue(plot.contains { $0.speed == 80 })
        XCTAssertNotEqual(report.samples[499].run, report.samples[501].run)
    }
}
