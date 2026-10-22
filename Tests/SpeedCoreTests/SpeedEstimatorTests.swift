import XCTest
@testable import SpeedCore

final class SpeedEstimatorTests: XCTestCase {
    func observation(_ t: Double, _ speed: Double, accuracy: Double = 0.5) -> SpeedObservation {
        SpeedObservation(timestamp: t, speed: speed, speedAccuracy: accuracy, horizontalAccuracy: 5)
    }
    func locked(_ speed: Double = 20, mode: SensorMode = .handheld) -> SpeedEstimator {
        var engine = SpeedEstimator(mode: mode)
        for t in 0...10 { _ = engine.ingest(observation(Double(t), speed), receivedAt: Double(t)) }
        return engine
    }

    func testStartupRequiresConfirmationRatherThanTrustingOneFix() {
        var engine = SpeedEstimator()
        XCTAssertNil(engine.estimate(at: 0).speed)
        XCTAssertEqual(engine.ingest(observation(0, 20), receivedAt: 0), .candidate)
        XCTAssertNil(engine.estimate(at: 0).speed)
        XCTAssertEqual(engine.ingest(observation(1, 20.2), receivedAt: 1), .accepted)
        XCTAssertEqual(engine.estimate(at: 1).speed!, 20.2, accuracy: 0.1)
    }

    func testInvalidNumbersCannotInitializeOrPoisonFilter() {
        for (speed, accuracy) in [(-1.0, 0.5), (.nan, 0.5), (.infinity, 0.5), (20, -1), (20, .nan), (20, 20)] {
            var engine = locked()
            XCTAssertEqual(engine.ingest(observation(11, speed, accuracy: accuracy), receivedAt: 11), .invalid)
            XCTAssertEqual(engine.estimate(at: 11).speed!, 20, accuracy: 0.1)
        }
    }

    func testTimestampValidationAndDuplicatesDoNotRenewFreshness() {
        var engine = locked()
        XCTAssertEqual(engine.ingest(observation(10, 20), receivedAt: 11), .outOfOrder)
        XCTAssertEqual(engine.ingest(observation(9, 20), receivedAt: 11), .outOfOrder)
        XCTAssertEqual(engine.ingest(observation(13, 20), receivedAt: 11), .invalidTime)
        XCTAssertEqual(engine.ingest(observation(11, 20), receivedAt: 20), .stale)
        XCTAssertNil(engine.estimate(at: 20).speed)
    }

    func testSingleSpeedSpikeIsRejectedAndDoesNotResetAge() {
        var engine = locked()
        XCTAssertEqual(engine.ingest(observation(11, 80, accuracy: 0.1), receivedAt: 11), .outlier)
        XCTAssertEqual(engine.estimate(at: 11).speed!, 20, accuracy: 0.2)
        XCTAssertEqual(engine.estimate(at: 11).observationAge!, 1, accuracy: 0.001)
        XCTAssertEqual(engine.ingest(observation(12, 20), receivedAt: 12), .accepted)
    }

    func testConsistentChangedSpeedCanRecoverInsteadOfPermanentLockout() {
        var engine = locked()
        _ = engine.ingest(observation(11, 35), receivedAt: 11)
        _ = engine.ingest(observation(12, 35), receivedAt: 12)
        _ = engine.ingest(observation(13, 35), receivedAt: 13)
        XCTAssertEqual(engine.estimate(at: 13).speed!, 35, accuracy: 1)
    }

    func testTunnelPredictionExpiresAndUncertaintyGrows() {
        var engine = locked()
        let live = engine.estimate(at: 10)
        let predicted = engine.estimate(at: 12)
        XCTAssertEqual(live.state, .measured)
        XCTAssertEqual(predicted.state, .predicted)
        XCTAssertGreaterThan(predicted.uncertainty!, live.uncertainty!)
        XCTAssertNil(engine.estimate(at: 13.1).speed)
        XCTAssertEqual(engine.estimate(at: 14).state, .unavailable)
    }

    func testRecoveryAfterLongOutageRequiresNewConfirmation() {
        var engine = locked()
        XCTAssertNil(engine.estimate(at: 100).speed)
        XCTAssertEqual(engine.ingest(observation(100, 5), receivedAt: 100), .candidate)
        XCTAssertNil(engine.estimate(at: 100).speed)
        _ = engine.ingest(observation(101, 5), receivedAt: 101)
        XCTAssertEqual(engine.estimate(at: 101).speed!, 5, accuracy: 0.1)
    }

    func testMeasuredLabelDoesNotPersistAcrossMissingUpdates() {
        var engine = locked()
        XCTAssertEqual(engine.estimate(at: 10.1).state, .measured)
        XCTAssertEqual(engine.estimate(at: 11.1).state, .predicted)
    }

    func testNoiseIsReducedWithoutInventingStationaryState() {
        var engine = SpeedEstimator()
        var rawSquared = 0.0, filteredSquared = 0.0, count = 0.0
        let noise = [1.2, -0.7, 0.8, -1.1, 0.4, -0.6, 1.0, -0.3]
        for t in 0..<200 {
            let n = noise[t % noise.count]
            _ = engine.ingest(observation(Double(t), 25 + n, accuracy: 1.5), receivedAt: Double(t))
            if t > 10, let speed = engine.estimate(at: Double(t)).speed {
                rawSquared += n * n
                filteredSquared += (speed - 25) * (speed - 25)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 180)
        XCTAssertLessThan(sqrt(filteredSquared / count), sqrt(rawSquared / count) * 0.9)
        XCTAssertGreaterThan(engine.estimate(at: 199).speed!, 24)
    }

    func testBetweenFixNoiseDoesNotAmplifyIntoAcceleration() {
        var engine = SpeedEstimator()
        var seed: UInt64 = 123456789
        func unit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11)/9007199254740992
        }
        var squared = 0.0, count = 0
        for i in 0..<2000 {
            let t = Double(i)/10
            if i % 10 == 0 {
                _ = engine.ingest(observation(t, 25 + sqrt(-2*log(max(1e-12, unit())))*cos(2 * .pi * unit())*0.8, accuracy: 0.8), receivedAt: t)
            }
            if i > 100, let speed = engine.estimate(at: t).speed {
                squared += pow(speed - 25, 2); count += 1
            }
        }
        XCTAssertLessThan(sqrt(squared/Double(count)), 0.8)
    }

    func testAccelerationAndEmergencyBrakingRemainResponsive() {
        var engine = locked(30)
        for t in 11...15 {
            let speed = 30 - Double(t - 10) * 6
            _ = engine.ingest(observation(Double(t), speed), receivedAt: Double(t))
            XCTAssertEqual(engine.estimate(at: Double(t)).speed!, speed, accuracy: 2.5)
        }
        XCTAssertLessThan(engine.estimate(at: 15).speed!, 1)
        for t in 16...22 {
            let speed = Double(t - 15) * 2
            _ = engine.ingest(observation(Double(t), speed), receivedAt: Double(t))
            XCTAssertEqual(engine.estimate(at: Double(t)).speed!, speed, accuracy: 1.5)
        }
    }

    func testInvalidHorizontalAccuracyCannotBecomeLive() {
        var engine = SpeedEstimator()
        let bad = SpeedObservation(timestamp: 0, speed: 20, speedAccuracy: 0.5, horizontalAccuracy: -1)
        XCTAssertEqual(engine.ingest(bad, receivedAt: 0), .invalid)
    }

    func testReadCallsDoNotChangeSubsequentFusion() {
        var first = locked(), second = locked()
        for i in 1...9 { _ = first.estimate(at: 10 + Double(i) / 10) }
        _ = first.ingest(observation(11, 22), receivedAt: 11)
        _ = second.ingest(observation(11, 22), receivedAt: 11)
        XCTAssertEqual(first.estimate(at: 11), second.estimate(at: 11))
    }

    func testHandheldMotionCannotChangeSpeedOrExtendTunnel() {
        var engine = locked()
        for i in 101...140 {
            _ = engine.ingest(MotionObservation(timestamp: Double(i)/10, acceleration: 8, rotationRate: 0), receivedAt: Double(i)/10)
        }
        XCTAssertNil(engine.estimate(at: 14).speed)
    }

    func testFixedMountBiasLearnsAndBrakingBridgesShortTunnel() {
        var engine = SpeedEstimator(mode: .mounted)
        for i in 0...200 {
            let t = Double(i) / 10
            if i % 10 == 0 { _ = engine.ingest(observation(t, 25), receivedAt: t) }
            _ = engine.ingest(MotionObservation(timestamp: t, acceleration: 0.15, rotationRate: 0), receivedAt: t)
        }
        for i in 201...240 {
            let t = Double(i) / 10
            _ = engine.ingest(MotionObservation(timestamp: t, acceleration: -1.85, rotationRate: 0), receivedAt: t)
        }
        let result = engine.estimate(at: 24)
        XCTAssertEqual(result.state, .predicted)
        XCTAssertEqual(result.speed!, 17, accuracy: 1.5)
        XCTAssertEqual(result.source, .inertial)
        XCTAssertNil(engine.estimate(at: 27).speed)
    }

    func testRotatingMountDisablesInertialBridge() {
        var engine = locked(mode: .mounted)
        _ = engine.ingest(MotionObservation(timestamp: 10.1, acceleration: 0, rotationRate: 2), receivedAt: 10.1)
        XCTAssertNil(engine.estimate(at: 14).speed)
    }

    func testZeroNeverBecomesNegativeDuringBrakingPrediction() {
        var engine = locked(2)
        _ = engine.ingest(observation(11, 0), receivedAt: 11)
        for t in [11.0, 12, 13, 14] {
            if let speed = engine.estimate(at: t).speed { XCTAssertGreaterThanOrEqual(speed, 0) }
        }
    }

    func testSparseFixesCannotConfirmStartup() {
        var engine = SpeedEstimator()
        _ = engine.ingest(observation(0, 20), receivedAt: 0)
        XCTAssertEqual(engine.ingest(observation(10, 20), receivedAt: 10), .candidate)
        XCTAssertNil(engine.estimate(at: 10).speed)
    }

    func testRotationRequiresExplicitRemountEvenAfterNewGoodFixes() {
        var engine = locked(mode: .mounted)
        _ = engine.ingest(MotionObservation(timestamp: 10.1, acceleration: 2, rotationRate: 2), receivedAt: 10.1)
        for i in 102...300 {
            let t = Double(i)/10
            if i % 10 == 0 && i <= 260 { _ = engine.ingest(observation(t, 20), receivedAt: t) }
            _ = engine.ingest(MotionObservation(timestamp: t, acceleration: 0, rotationRate: 0), receivedAt: t)
        }
        XCTAssertNil(engine.estimate(at: 30).speed)
    }

    func testRepeatedLargeInnovationsCannotCreatePhantomAccelerationAfterRejection() {
        var engine = locked()
        for t in 11...20 {
            let spike = t % 2 == 0 ? 120.0 : 70.0
            XCTAssertNotEqual(engine.ingest(observation(Double(t), spike), receivedAt: Double(t)), .accepted)
        }
        XCTAssertNil(engine.estimate(at: 20).speed)
    }

    func testNonfiniteQueryAndMotionAreSafe() {
        var engine = locked(mode: .mounted)
        XCTAssertNil(engine.estimate(at: .nan).speed)
        XCTAssertNil(engine.estimate(at: .infinity).speed)
        XCTAssertEqual(engine.ingest(MotionObservation(timestamp: 11, acceleration: .nan, rotationRate: 0), receivedAt: 11), .invalid)
        XCTAssertEqual(engine.estimate(at: 10).speed!, 20, accuracy: 0.1)
    }

    func testUnderstatedGNSSAccuracyRaisesNoiseScaleAndSmoothsMore() {
        var honest = locked(), noisy = locked()
        var seed: UInt64 = 7
        func jitter() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / 9007199254740992 - 0.5) * 4   // ±2 m/s, σ ≈ 1.15
        }
        var honestSwing = 0.0, noisySwing = 0.0, previous: (Double, Double)?
        for t in 11...70 {
            let error = jitter(), time = Double(t)
            _ = honest.ingest(observation(time, 20 + error, accuracy: 1.2), receivedAt: time)
            _ = noisy.ingest(observation(time, 20 + error, accuracy: 0.4), receivedAt: time)
            let pair = (honest.estimate(at: time).speed!, noisy.estimate(at: time).speed!)
            if t > 40, let previous { honestSwing += abs(pair.0 - previous.0); noisySwing += abs(pair.1 - previous.1) }
            previous = pair
        }
        XCTAssertGreaterThan(noisy.diagnostics(at: 70).gnssNoiseScale!, 3)
        XCTAssertLessThan(honest.diagnostics(at: 70).gnssNoiseScale!, 1.5)
        // Once learned, the understated receiver is not followed more closely than the honest one.
        XCTAssertLessThan(noisySwing, honestSwing * 1.3)
    }

    func testPersistentlyLargeInnovationsWidenButNeverNarrowReportedUncertainty() throws {
        var honest = locked(), noisy = locked(), steady = locked()
        var seed: UInt64 = 11
        func jitter() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / 9007199254740992 - 0.5) * 6   // ±3 m/s, σ ≈ 1.7
        }
        for t in 11...70 {
            let error = jitter(), time = Double(t)
            _ = honest.ingest(observation(time, 20 + error, accuracy: 1.8), receivedAt: time)
            // Beyond what the GNSS variance multiplier can absorb.
            _ = noisy.ingest(observation(time, 20 + error, accuracy: 0.2), receivedAt: time)
            // Exact fixes give NIS ≪ 1; that must not shrink the stated uncertainty.
            _ = steady.ingest(observation(time, 20, accuracy: 0.5), receivedAt: time)
        }
        let diagnostics = noisy.diagnostics(at: 70.5)
        let scale = try XCTUnwrap(diagnostics.uncertaintyScale)
        XCTAssertGreaterThan(scale, 1.3)
        XCTAssertLessThanOrEqual(scale, 3)
        let unscaled = max(diagnostics.covarianceSpeedSigma!, diagnostics.uncertaintyFloor!)
        XCTAssertEqual(noisy.estimate(at: 70.5).uncertainty!, scale * unscaled, accuracy: 1e-9)
        XCTAssertLessThan(honest.diagnostics(at: 70.5).uncertaintyScale!, 1.2)
        let quiet = steady.diagnostics(at: 70.5)
        XCTAssertEqual(quiet.uncertaintyScale, 1)
        XCTAssertEqual(steady.estimate(at: 70.5).uncertainty!,
                       max(quiet.covarianceSpeedSigma!, quiet.uncertaintyFloor!), accuracy: 1e-9)
    }
}
