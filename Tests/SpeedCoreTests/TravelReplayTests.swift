import XCTest
@testable import SpeedCore

final class TravelReplayTests: XCTestCase {
    func testActivityChangesSurviveJournalRoundTripAndReplay() throws {
        var replay = SpeedReplay()
        let source = ReplayEvent(receivedAt: 0, activitySource: .available)
        _ = try replay.consume(source)
        let event = ReplayEvent(receivedAt: 0.1, activity: ActivityObservation(timestamp: 0.1, confidence: .high, automotive: true))
        let encoded = try JSONEncoder().encode(event)
        _ = try replay.consume(ReplayEvent.decode(encoded))
        let output = try replay.consume(ReplayEvent(receivedAt: 2.1))
        XCTAssertEqual(output.travel.mode, .vehicle)
        XCTAssertNil(output.estimate.speed) // vehicle detection never fabricates GNSS speed
    }
    func testLifecycleResetAndPermissionRevocationClearTravel() throws {
        var replay = SpeedReplay()
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activitySource: .available))
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activity: ActivityObservation(timestamp: 0, confidence: .high, cycling: true)))
        XCTAssertEqual(try replay.consume(ReplayEvent(receivedAt: 2)).travel.mode, .independent)
        XCTAssertEqual(try replay.consume(ReplayEvent(receivedAt: 3, activitySource: .denied)).travel.mode, .unknown)
        XCTAssertEqual(try replay.consume(ReplayEvent(receivedAt: 4, reset: true)).travel.source, .waiting)
    }
    func testOldLogsRemainReadableWithoutActivityAndAmbiguityFails() throws {
        var replay = SpeedReplay()
        let legacy = try ReplayEvent.decode(Data(#"{"receivedAt":0}"#.utf8))
        XCTAssertEqual(try replay.consume(legacy).travel.mode, .unknown)
        let mixed = ReplayEvent(receivedAt: 1, activity: ActivityObservation(timestamp: 1, confidence: .high, walking: true), activitySource: .available)
        XCTAssertThrowsError(try replay.consume(mixed))
    }
    func testWallClockSpeedResetDoesNotEraseUnchangedActivityState() throws {
        var replay = SpeedReplay()
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activitySource: .available))
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activity: ActivityObservation(timestamp: 0, confidence: .high, automotive: true)))
        _ = try replay.consume(ReplayEvent(receivedAt: 2))
        let output = try replay.consume(ReplayEvent(receivedAt: 3, resetSpeedOnly: true))
        XCTAssertEqual(output.travel.mode, .vehicle)
        XCTAssertNil(output.estimate.speed)
    }

    func testRecognizingVehicleDoesNotEnableMountedInertialFusion() throws {
        var replay = SpeedReplay()
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activitySource: .available))
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activity: ActivityObservation(timestamp: 0, confidence: .high, automotive: true)))
        for t in 0...10 {
            _ = try replay.consume(ReplayEvent(receivedAt: Double(t), speed: SpeedObservation(timestamp: Double(t), speed: 20, speedAccuracy: 0.5, horizontalAccuracy: 5)))
        }
        for i in 101...140 {
            let t = Double(i)/10
            _ = try replay.consume(ReplayEvent(receivedAt: t, motion: MotionObservation(timestamp: t, acceleration: 5, rotationRate: 0)))
        }
        let output = try replay.consume(ReplayEvent(receivedAt: 14))
        XCTAssertEqual(output.travel.mode, .vehicle)
        XCTAssertNil(output.estimate.speed)
    }
}
