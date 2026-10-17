import XCTest
@testable import SpeedCore

final class SensorBoundaryTests: XCTestCase {
    func testGravityRemovedAccelerationUsesSignedVehicleAxisAndSIUnits() throws {
        let forward = try MountAxis(x: 0, y: 2, z: 0)
        XCTAssertEqual(forward.acceleration(x: 0.3, y: -0.2, z: 0.8), -1.96133, accuracy: 1e-5)
        XCTAssertThrowsError(try MountAxis(x: 0, y: 0, z: 0))
        XCTAssertThrowsError(try MountAxis(x: .nan, y: 1, z: 0))
    }
    func testMountMonitorDetectsSlowOrientationChangesAndLatches() {
        var monitor = MountMonitor()
        XCTAssertTrue(monitor.accepts(x: 0, y: 0, z: 0, w: 1))
        XCTAssertTrue(monitor.accepts(x: 0, y: 0, z: 0, w: -1))
        // 20 degrees yaw, even if instantaneous angular rate is very small.
        XCTAssertFalse(monitor.accepts(x: 0, y: 0, z: 0.17364818, w: 0.98480775))
        XCTAssertFalse(monitor.accepts(x: 0, y: 0, z: 0, w: 1))
    }

    func testLocationClockConvertsWallTimeAndRejectsClockJump() {
        var clock = LocationClock()
        XCTAssertEqual(clock.convert(fixWallTime: 999, wallNow: 1000, monotonicNow: 20), 19)
        XCTAssertEqual(clock.convert(fixWallTime: 1001, wallNow: 1002, monotonicNow: 22), 21)
        XCTAssertNil(clock.convert(fixWallTime: 2000, wallNow: 2000, monotonicNow: 23))
        XCTAssertEqual(clock.convert(fixWallTime: 2001, wallNow: 2001, monotonicNow: 24), 24)
    }
    func testJournalRoundTripPreservesReceiptTimeAndUnavailable() throws {
        let event = ReplayEvent(receivedAt: 4, speed: SpeedObservation(timestamp: 3, speed: 20, speedAccuracy: 1, horizontalAccuracy: 5))
        let line = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ReplayEvent.self, from: line)
        XCTAssertEqual(decoded.receivedAt, 4)
        XCTAssertEqual(decoded.speed?.timestamp, 3)
        var replay = SpeedReplay()
        XCTAssertNil(try replay.consume(decoded).estimate.speed)
        let output = try replay.consume(ReplayEvent(receivedAt: 5, speed: SpeedObservation(timestamp: 4, speed: 20, speedAccuracy: 1, horizontalAccuracy: 5)))
        XCTAssertNotNil(output.estimate.speed)
        XCTAssertThrowsError(try replay.consume(ReplayEvent(receivedAt: 2)))
    }
    func testRecordedInvalidSensorNumberCanBeReplayedAndRejected() throws {
        var replay = SpeedReplay()
        let line = Data(#"{"receivedAt":0,"speed":{"timestamp":0,"speed":"NaN","speedAccuracy":0.5,"horizontalAccuracy":5}}"#.utf8)
        let event = try ReplayEvent.decode(line)
        let result = try replay.consume(event)
        XCTAssertEqual(result.result, .invalid)
        XCTAssertNil(result.estimate.speed)
    }

    func testDelayedGPSDoesNotPretendItsMeasurementIsNew() {
        var engine = SpeedEstimator()
        _ = engine.ingest(SpeedObservation(timestamp: 0, speed: 20, speedAccuracy: 0.5, horizontalAccuracy: 5), receivedAt: 1.5)
        _ = engine.ingest(SpeedObservation(timestamp: 1, speed: 20, speedAccuracy: 0.5, horizontalAccuracy: 5), receivedAt: 2.5)
        let result = engine.estimate(at: 2.5)
        XCTAssertEqual(result.state, .predicted)
        XCTAssertEqual(result.observationAge!, 1.5, accuracy: 0.001)
    }

    func testReplayCannotSilentlyPickOneOfTwoMeasurements() {
        var replay = SpeedReplay()
        let speed = SpeedObservation(timestamp: 0, speed: 20, speedAccuracy: 1, horizontalAccuracy: 5)
        let motion = MotionObservation(timestamp: 0, acceleration: 0, rotationRate: 0)
        XCTAssertThrowsError(try replay.consume(ReplayEvent(receivedAt: 0, speed: speed, motion: motion)))
    }
}
