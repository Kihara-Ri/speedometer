import XCTest
@testable import SpeedCore

final class TravelModeRecognizerTests: XCTestCase {
    func activity(_ t: Double = 0, confidence: ActivityConfidence = .high,
                  automotive: Bool = false, walking: Bool = false, running: Bool = false,
                  cycling: Bool = false, stationary: Bool = false, unknown: Bool = false) -> ActivityObservation {
        ActivityObservation(timestamp: t, confidence: confidence, automotive: automotive, walking: walking,
                            running: running, cycling: cycling, stationary: stationary, unknown: unknown)
    }
    func ready() -> TravelModeRecognizer {
        var recognizer = TravelModeRecognizer()
        recognizer.setSource(.available, at: 0)
        return recognizer
    }
    func vehicle() -> TravelModeRecognizer {
        var recognizer = ready()
        _ = recognizer.ingest(activity(automotive: true), receivedAt: 0)
        _ = recognizer.advance(to: 2)
        return recognizer
    }
    func speed(_ t: Double, _ value: Double, accuracy: Double = 0.5) -> SpeedObservation {
        SpeedObservation(timestamp: t, speed: value, speedAccuracy: accuracy, horizontalAccuracy: 5)
    }

    func testStartsUnknownAndUnavailableOrDeniedNeverGuess() {
        var recognizer = TravelModeRecognizer()
        XCTAssertEqual(recognizer.advance(to: 0).mode, .unknown)
        for source in [ActivitySource.unavailable, .denied, .restricted, .stopped] {
            recognizer.setSource(source, at: 1)
            _ = recognizer.ingest(activity(1, automotive: true), receivedAt: 1)
            XCTAssertEqual(recognizer.advance(to: 10).mode, .unknown)
        }
    }
    func testVehicleRequiresSustainedEvidenceRatherThanOneCallback() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(automotive: true), receivedAt: 0)
        XCTAssertEqual(recognizer.advance(to: 1).mode, .unknown)
        XCTAssertEqual(recognizer.advance(to: 2).mode, .vehicle)
    }
    func testUnchangedSystemActivityRemainsCurrentWithoutRepeatedCallbacks() {
        var recognizer = vehicle()
        XCTAssertEqual(recognizer.advance(to: 600).mode, .vehicle)
    }
    func testWalkingRunningAndCyclingAllMapToIndependent() {
        for input in [activity(walking: true), activity(running: true), activity(cycling: true)] {
            var recognizer = ready()
            _ = recognizer.ingest(input, receivedAt: 0)
            XCTAssertEqual(recognizer.advance(to: 2).mode, .independent)
        }
    }
    func testMediumConfidenceTakesLongerAndLowConfidenceDoesNotConfirm() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(confidence: .medium, automotive: true), receivedAt: 0)
        XCTAssertEqual(recognizer.advance(to: 2).mode, .unknown)
        XCTAssertEqual(recognizer.advance(to: 4).mode, .vehicle)
        _ = recognizer.ingest(activity(5, confidence: .low, walking: true), receivedAt: 5)
        XCTAssertNotEqual(recognizer.advance(to: 20).mode, .independent)
    }
    func testStationaryAndAutomotiveAtRedLightStillMeansVehicle() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(automotive: true, stationary: true), receivedAt: 0)
        _ = recognizer.ingestSpeed(speed(1, 0), receivedAt: 1)
        XCTAssertEqual(recognizer.advance(to: 2).mode, .vehicle)
    }
    func testStationaryAloneCannotTellHomeFromParkedVehicle() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(stationary: true), receivedAt: 0)
        XCTAssertEqual(recognizer.advance(to: 100).mode, .unknown)
    }
    func testBriefStationaryRetainsContextThenBecomesUnknown() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, stationary: true), receivedAt: 3)
        XCTAssertEqual(recognizer.advance(to: 20).mode, .vehicle)
        XCTAssertEqual(recognizer.advance(to: 124).mode, .unknown)
    }
    func testHighSpeedAloneCannotDistinguishCyclingAndVehicle() {
        var recognizer = ready()
        _ = recognizer.ingestSpeed(speed(0, 20), receivedAt: 0)
        XCTAssertEqual(recognizer.advance(to: 1).mode, .unknown)
    }
    func testCyclingDoesNotBecomeVehicleEvenAtHighSpeed() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(cycling: true), receivedAt: 0)
        _ = recognizer.ingestSpeed(speed(2, 15), receivedAt: 2)
        XCTAssertEqual(recognizer.advance(to: 2).mode, .independent)
    }
    func testConflictingFlagsAndUnknownClearClassification() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, automotive: true, cycling: true), receivedAt: 3)
        XCTAssertEqual(recognizer.advance(to: 3).reason, .conflictingActivity)
        XCTAssertEqual(recognizer.advance(to: 3).mode, .unknown)
        _ = recognizer.ingest(activity(4, unknown: true), receivedAt: 4)
        XCTAssertEqual(recognizer.advance(to: 4).mode, .unknown)
    }
    func testWalkingInsideMovingTrainIsNotAutomaticallyAnExit() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, walking: true), receivedAt: 3)
        _ = recognizer.ingestSpeed(speed(3, 25), receivedAt: 3)
        XCTAssertNotEqual(recognizer.advance(to: 3).mode, .independent)
        // Losing GNSS must not turn that contradiction into evidence of alighting.
        XCTAssertNotEqual(recognizer.advance(to: 20).mode, .independent)
    }
    func testVehicleToWalkingRequiresCompatibleSpeedAndDebounce() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, walking: true), receivedAt: 3)
        for t in 3...8 {
            _ = recognizer.ingestSpeed(speed(Double(t), 1.4), receivedAt: Double(t))
            let output = recognizer.advance(to: Double(t))
            if t < 8 { XCTAssertNotEqual(output.mode, .independent) }
        }
        XCTAssertEqual(recognizer.advance(to: 8).mode, .independent)
    }
    func testTransientActivityDoesNotFlipModeAndLowConfidenceExpires() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, cycling: true), receivedAt: 3)
        XCTAssertEqual(recognizer.advance(to: 4).mode, .vehicle)
        _ = recognizer.ingest(activity(4.5, automotive: true), receivedAt: 4.5)
        XCTAssertEqual(recognizer.advance(to: 5).mode, .vehicle)
        _ = recognizer.ingest(activity(6, confidence: .low, automotive: true), receivedAt: 6)
        XCTAssertEqual(recognizer.advance(to: 15).mode, .unknown)
    }
    func testInvalidOutOfOrderActivityCannotReplaceCurrentEvidence() {
        var recognizer = vehicle()
        XCTAssertFalse(recognizer.ingest(activity(1, walking: true), receivedAt: 3))
        XCTAssertFalse(recognizer.ingest(activity(.nan, walking: true), receivedAt: 3))
        XCTAssertFalse(recognizer.ingest(activity(5, walking: true), receivedAt: 3))
        XCTAssertEqual(recognizer.advance(to: 3).mode, .vehicle)
    }
    func testOldOrInaccurateSpeedDoesNotVetoWalking() {
        var recognizer = ready()
        _ = recognizer.ingest(activity(walking: true), receivedAt: 0)
        XCTAssertFalse(recognizer.ingestSpeed(speed(2, 25, accuracy: -1), receivedAt: 2))
        XCTAssertEqual(recognizer.advance(to: 2).mode, .independent)
        recognizer.reset()
        recognizer.setSource(.available, at: 3)
        _ = recognizer.ingest(activity(3, walking: true), receivedAt: 3)
        _ = recognizer.ingestSpeed(speed(3, 25), receivedAt: 3)
        XCTAssertEqual(recognizer.advance(to: 6).mode, .independent)
    }
    func testSpeedConflictTimeDoesNotCountTowardAlightingConfirmation() {
        var recognizer = vehicle()
        _ = recognizer.ingest(activity(3, walking: true), receivedAt: 3)
        for t in 3...10 {
            _ = recognizer.ingestSpeed(speed(Double(t), 25), receivedAt: Double(t))
            _ = recognizer.advance(to: Double(t))
        }
        _ = recognizer.ingestSpeed(speed(11, 1.4), receivedAt: 11)
        XCTAssertNotEqual(recognizer.advance(to: 11).mode, .independent)
        for t in 12...16 {
            _ = recognizer.ingestSpeed(speed(Double(t), 1.4), receivedAt: Double(t))
            _ = recognizer.advance(to: Double(t))
        }
        XCTAssertEqual(recognizer.advance(to: 16).mode, .independent)
    }

    func testResetClearsVehicleContextAcrossSessions() {
        var recognizer = vehicle()
        recognizer.reset()
        recognizer.setSource(.available, at: 10)
        _ = recognizer.ingest(activity(10, stationary: true), receivedAt: 10)
        XCTAssertEqual(recognizer.advance(to: 12).mode, .unknown)
    }
}
