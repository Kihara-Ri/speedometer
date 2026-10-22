import XCTest
@testable import SpeedCore

final class StationaryTests: XCTestCase {
    private func activity(_ t: Double, automotive: Bool = false, stationary: Bool = true) -> ReplayEvent {
        ReplayEvent(receivedAt: t, activity: ActivityObservation(timestamp: t, confidence: .high,
            automotive: automotive, walking: !stationary, stationary: stationary))
    }
    private func position(_ t: Double, longitude: Double = 139) -> ReplayEvent {
        var event = ReplayEvent(receivedAt: t, speed: SpeedObservation(timestamp: t, speed: -1,
            speedAccuracy: -1, horizontalAccuracy: 10))
        event.locationDetails = LocationDetails(wallTime: 1000+t, latitude: 35, longitude: longitude,
            altitude: 0, verticalAccuracy: 10, course: -1, courseAccuracy: -1, simulated: nil, accessory: nil,
            rawSpeed: -1, rawSpeedAccuracy: -1, rawHorizontalAccuracy: 10)
        return event
    }
    private func motion(_ t: Double, acceleration: Double = 0) -> ReplayEvent {
        ReplayEvent(receivedAt: t, rawMotion: RawMotion(acceleration: [acceleration,0,0], gravity: [0,0,1],
            rotationRate: [0,0,0], quaternion: [0,0,0,1], timestamp: t))
    }
    private func confirmed(automotive: Bool = false, positions: Bool = true) throws -> SpeedReplay {
        var replay = SpeedReplay()
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activitySource: .available))
        _ = try replay.consume(activity(0, automotive: automotive))
        if positions { _ = try replay.consume(position(0)) }
        for i in 0...250 { _ = try replay.consume(motion(Double(i)/50)) }
        if positions { _ = try replay.consume(position(5)) }
        return replay
    }
    func testInvalidGPSVelocityCanStillDisplayConfirmedStationaryZero() throws {
        var replay = try confirmed()
        let result = try replay.consume(ReplayEvent(receivedAt: 5))
        XCTAssertEqual(result.estimate.speed, 0)
        XCTAssertEqual(result.estimate.source.rawValue, "stationary")
        XCTAssertNil(result.estimate.uncertainty, "inferred zero must not claim calibrated GNSS accuracy")
    }
    func testQuietPhoneOnVehicleIsNotProofOfZeroSpeed() throws {
        var replay = try confirmed(automotive: true)
        XCTAssertNil(try replay.consume(ReplayEvent(receivedAt: 5)).estimate.speed)
    }
    func testQuietActivityWithoutPositionEvidenceDoesNotInventZero() throws {
        var replay = try confirmed(positions: false)
        XCTAssertNil(try replay.consume(ReplayEvent(receivedAt: 5)).estimate.speed)
    }
    func testHandShakingDoesNotRevokeAnAlreadyConfirmedGroundStop() throws {
        var replay = try confirmed()
        XCTAssertEqual(try replay.consume(ReplayEvent(receivedAt: 5)).estimate.speed, 0)
        for i in 251...750 {
            let t = Double(i)/50
            let result = try replay.consume(motion(t, acceleration: i % 2 == 0 ? 0.5 : -0.5))
            XCTAssertEqual(result.estimate.speed, 0, "hand motion is not ground travel")
            if i % 250 == 0 { _ = try replay.consume(position(t)) }
        }
    }
    func testWalkingImmediatelyRevokesZeroEvenAfterHandShaking() throws {
        var walking = try confirmed()
        _ = try walking.consume(motion(5.02, acceleration: 0.5))
        XCTAssertNil(try walking.consume(activity(5.04, stationary: false)).estimate.speed)
    }
    func testShakingCannotInitializeAStopOrReuseAStopAfterSensorLoss() throws {
        var replay = try confirmed()
        _ = try replay.consume(ReplayEvent(receivedAt: 6))
        XCTAssertNil(try replay.consume(motion(6.02, acceleration: 0.5)).estimate.speed)
        for i in 302...800 {
            let result = try replay.consume(motion(Double(i)/50, acceleration: 0.5))
            XCTAssertNil(result.estimate.speed)
        }
    }
    func testPositionMovementAndCredibleSpeedImmediatelyRevokeZero() throws {
        var replay = try confirmed()
        XCTAssertNil(try replay.consume(position(5.1, longitude: 139.001)).estimate.speed)
        var moving = try confirmed()
        let output = try moving.consume(ReplayEvent(receivedAt: 5.1,
            speed: SpeedObservation(timestamp: 5.1, speed: 20, speedAccuracy: 0.5, horizontalAccuracy: 5)))
        XCTAssertNotEqual(output.estimate.source.rawValue, "stationary")
        XCTAssertNotEqual(output.estimate.speed, 0)
    }
    func testSensorGapStalePositionsAndDeniedActivityRevokeZero() throws {
        var gap = try confirmed()
        XCTAssertNil(try gap.consume(ReplayEvent(receivedAt: 6)).estimate.speed)
        var stale = try confirmed()
        for i in 251...1300 { _ = try stale.consume(motion(Double(i)/50)) }
        XCTAssertNil(try stale.consume(ReplayEvent(receivedAt: 26)).estimate.speed)
        var denied = try confirmed()
        XCTAssertNil(try denied.consume(ReplayEvent(receivedAt: 5, activitySource: .denied)).estimate.speed)
    }
    func testCachedPositionsAndHistoricalActivityStartCannotSkipConfirmation() throws {
        var replay = SpeedReplay()
        _ = try replay.consume(ReplayEvent(receivedAt: 0, activitySource: .available))
        _ = try replay.consume(activity(0))
        _ = try replay.consume(position(0))
        for i in 0...250 { _ = try replay.consume(motion(Double(i)/50)) }
        var cached = position(5)
        cached.speed?.timestamp = 0
        XCTAssertNil(try replay.consume(cached).estimate.speed)
    }
    func testDirectEstimatorSpeedInputAlsoVetoesStationaryOverride() {
        var engine = SpeedEstimator()
        engine.observeStationaryEvidence(ReplayEvent(receivedAt: 0, activitySource: .available))
        engine.observeStationaryEvidence(activity(0))
        engine.observeStationaryEvidence(position(0))
        for i in 0...250 { engine.observeStationaryEvidence(motion(Double(i)/50)) }
        engine.observeStationaryEvidence(position(5))
        XCTAssertEqual(engine.estimate(at: 5).speed, 0)
        _ = engine.ingest(SpeedObservation(timestamp: 5.1, speed: 20, speedAccuracy: 0.5, horizontalAccuracy: 5), receivedAt: 5.1)
        XCTAssertNil(engine.estimate(at: 5.1).speed, "one moving fix needs confirmation, and must revoke zero immediately")
    }
}
