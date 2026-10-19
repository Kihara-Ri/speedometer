import XCTest
@testable import SpeedCore

final class RailArrivalTests: XCTestCase {
    // Two 65-second cycles: acceleration, cruise, braking, then a sustained stop.
    private func sample(_ t: Double, _ speed: Double, rotation: Double = 0) -> ReplayEvent {
        ReplayEvent(receivedAt: t,
            speed: SpeedObservation(timestamp: t, speed: speed, speedAccuracy: 0.2, horizontalAccuracy: 5),
            rawMotion: RawMotion(acceleration: [0,0,0], gravity: [0,0,-1],
                rotationRate: [0,0,rotation], quaternion: [0,0,0,1], timestamp: t))
    }
    private func cycle(_ recognizer: inout RailArrivalRecognizer, start: Int,
                       rotating: Bool = false, endSpeed: Double = 0) -> [RailArrivalUpdate] {
        (0...64).map { i in
            let speed = i <= 12 ? Double(i) : i <= 37 ? 12.0 : max(endSpeed, 12 - Double(i - 37))
            return recognizer.consume(sample(Double(start + i), speed, rotation: rotating ? 1 : 0))
        }
    }

    func testOnlyRepeatedCompleteRunsProduceOneCandidateAfterStopping() throws {
        var recognizer = RailArrivalRecognizer()
        XCTAssertTrue(cycle(&recognizer, start: 0).allSatisfy { $0.created == nil })
        let updates = cycle(&recognizer, start: 65)
        let candidates = updates.compactMap(\.created)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.stoppedAt, 114)
        XCTAssertEqual(candidate.evidenceStartedAt, 3)
        XCTAssertGreaterThanOrEqual(candidate.detectedAt, 118)
        XCTAssertTrue(updates.suffix(4).allSatisfy { $0.isRailLike })
    }

    func testSlowingWithoutStoppingAndRotatingPhoneDoNotPrompt() {
        for (rotation, endSpeed) in [(false, 3.0), (true, 0.0)] {
            var recognizer = RailArrivalRecognizer()
            _ = cycle(&recognizer, start: 0)
            XCTAssertTrue(cycle(&recognizer, start: 65, rotating: rotation, endSpeed: endSpeed)
                .allSatisfy { $0.created == nil })
        }
    }

    func testHumanActivityVetoesRailEvidence() {
        for cycling in [false, true] {
            var recognizer = RailArrivalRecognizer()
            _ = cycle(&recognizer, start: 0)
            _ = recognizer.consume(ReplayEvent(receivedAt: 64, activity: ActivityObservation(
                timestamp: 64, confidence: .high, walking: !cycling, cycling: cycling)))
            XCTAssertTrue(cycle(&recognizer, start: 65).allSatisfy { $0.created == nil })
        }
    }

    func testMissingSpeedNeverBecomesAStopAndGapBreaksEvidence() {
        var recognizer = RailArrivalRecognizer()
        _ = cycle(&recognizer, start: 0)
        for t in 65...105 { _ = recognizer.consume(sample(Double(t), 12)) }
        for t in 106...134 {
            XCTAssertNil(recognizer.consume(ReplayEvent(receivedAt: Double(t))).created)
        }
        XCTAssertTrue(cycle(&recognizer, start: 135).allSatisfy { $0.created == nil })
    }

    func testShortStopsAbruptDropsAndMissingMotionDoNotPrompt() {
        for mode in 0...2 {
            var recognizer = RailArrivalRecognizer()
            _ = cycle(&recognizer, start: 0)
            for i in 0...64 {
                var event = sample(Double(65 + i), i <= 12 ? Double(i) : i <= 37 ? 12 : max(0, 12 - Double(i - 37)))
                if mode == 0, i >= 51 { event = sample(Double(65 + i), 3) }
                if mode == 1 { event = sample(Double(65 + i), i <= 12 ? Double(i) : i <= 37 ? 12 : 0) }
                if mode == 2 { event.rawMotion = nil }
                XCTAssertNil(recognizer.consume(event).created)
            }
        }
    }

    func testFeedbackIsAssociatedOnceAndExpiresWithoutBecomingDenial() throws {
        for answer in [RailArrivalAnswer.confirmed, .denied] {
            var recognizer = RailArrivalRecognizer()
            _ = cycle(&recognizer, start: 0)
            let candidate = try XCTUnwrap(cycle(&recognizer, start: 65).compactMap(\.created).first)
            var response = ReplayEvent(receivedAt: 130)
            response.railFeedback = RailArrivalFeedback(candidateID: candidate.id, answer: answer)
            let update = recognizer.consume(response)
            XCTAssertNil(update.current)
            XCTAssertEqual(update.resolved?.answer, answer)
            XCTAssertEqual(update.resolved?.candidateID, candidate.id)
            XCTAssertNil(recognizer.consume(response).resolved)
        }
        var recognizer = RailArrivalRecognizer()
        _ = cycle(&recognizer, start: 0); _ = cycle(&recognizer, start: 65)
        let lost = recognizer.consume(ReplayEvent(receivedAt: 133))
        XCTAssertEqual(lost.resolved?.answer, .unanswered)
        XCTAssertNil(lost.current)
    }

    func testTimeoutResumptionResetAndStopCloseCandidate() throws {
        for reason in ["expired", "resumed", "reset", "recordingEnded"] {
            var recognizer = RailArrivalRecognizer()
            _ = cycle(&recognizer, start: 0); _ = cycle(&recognizer, start: 65)
            var last: RailArrivalUpdate?
            if reason == "expired" {
                var resolutions: [RailArrivalResolution] = []
                for t in 130...155 {
                    last = recognizer.consume(sample(Double(t), 0))
                    if let resolution = last?.resolved { resolutions.append(resolution) }
                }
                XCTAssertEqual(resolutions.count, 1)
                XCTAssertEqual(resolutions.first?.answer, .unanswered)
                XCTAssertEqual(resolutions.first?.reason, .expired)
            } else {
                var event = sample(130, reason == "resumed" ? 3 : 0)
                if reason == "reset" { event.reset = true }
                if reason == "recordingEnded" { event.lifecycle = "recordingEnded" }
                last = recognizer.consume(event)
            }
            // For timeout retain the resolution at its occurrence, rather than the final tick.
            if reason != "expired" {
                XCTAssertEqual(last?.resolved?.reason.rawValue, reason)
                XCTAssertEqual(last?.resolved?.answer, .unanswered)
            }
            XCTAssertNil(last?.current)
        }
    }

    func testRejectedStaleAndReversedSpeedsCannotCreateCandidates() {
        var recognizer = RailArrivalRecognizer()
        _ = cycle(&recognizer, start: 0)
        for t in 65...129 {
            var event = sample(Double(t), 0)
            event.speed?.timestamp = Double(t - 10)
            XCTAssertNil(recognizer.consume(event).created)
        }
        XCTAssertNil(recognizer.consume(sample(0, 0)).created)
        XCTAssertTrue(cycle(&recognizer, start: 130).allSatisfy { $0.created == nil })
    }

    func testLiveAndReplayAgreeAndStoredPredictionsCannotCreateEvidence() throws {
        var direct = RailArrivalRecognizer()
        var replay = SpeedReplay()
        var directCandidates: [RailArrivalCandidate] = []
        var replayCandidates: [RailArrivalCandidate] = []
        for t in 0...129 {
            let i = t % 65
            let speed = i <= 12 ? Double(i) : i <= 37 ? 12 : max(0, 12 - Double(i - 37))
            let event = sample(Double(t), speed)
            let output = try replay.consume(event)
            let live = direct.consume(event, acceptedSpeed: output.result == .accepted)
            if let candidate = live.created { directCandidates.append(candidate) }
            if let candidate = output.rail.created { replayCandidates.append(candidate) }
        }
        XCTAssertEqual(replayCandidates.count, 1)
        XCTAssertEqual(replayCandidates, directCandidates)
        let candidate = try XCTUnwrap(replayCandidates.first)
        var feedback = ReplayEvent(receivedAt: 130)
        feedback.railFeedback = RailArrivalFeedback(candidateID: candidate.id, answer: .confirmed)
        let encoded = try JSONEncoder().encode(feedback)
        let decoded = try ReplayEvent.decode(encoded)
        XCTAssertEqual(try replay.consume(decoded).rail.resolved?.answer, .confirmed)
        var fresh = SpeedReplay()
        var prediction = ReplayEvent(receivedAt: 131)
        prediction.railCandidate = candidate
        XCTAssertNil(try fresh.consume(prediction).rail.current)
        XCTAssertNil(try fresh.consume(ReplayEvent.decode(Data(#"{"receivedAt":132}"#.utf8))).rail.current)
    }

    func testWrongFeedbackAndRejectedObservationDoNotConfirmArrival() throws {
        var recognizer = RailArrivalRecognizer()
        _ = cycle(&recognizer, start: 0); _ = cycle(&recognizer, start: 65)
        var event = ReplayEvent(receivedAt: 130)
        event.railFeedback = RailArrivalFeedback(candidateID: "unknown", answer: .confirmed)
        XCTAssertNil(recognizer.consume(event).resolved)
        let update = recognizer.consume(sample(130, 0), acceptedSpeed: false)
        XCTAssertEqual(update.resolved?.answer, .unanswered)
        XCTAssertNil(update.current)
    }

    func testCruisingBetweenBriefSlowdownAndShortFinalBrakeCannotCountAsSustainedBraking() {
        var recognizer = RailArrivalRecognizer()
        _ = cycle(&recognizer, start: 0)
        for i in 0...80 {
            let speed: Double
            if i <= 12 { speed = Double(i) }
            else if i <= 37 { speed = 12 }
            else if i <= 62 { speed = 11.2 }
            else { speed = max(0, 11.2 - Double(i - 62) * 2.24) }
            XCTAssertNil(recognizer.consume(sample(Double(65 + i), speed)).created)
        }
    }

    func testSecondRecordingKeepsCandidateIdentityWhenReplayedAlone() throws {
        var live = RailArrivalRecognizer()
        _ = cycle(&live, start: 0); _ = cycle(&live, start: 65)
        let reset = ReplayEvent(receivedAt: 130, reset: true)
        _ = live.consume(reset)
        var replay = SpeedReplay()
        _ = try replay.consume(reset)
        var liveID: String?
        var replayID: String?
        for t in 131...260 {
            let i = (t - 131) % 65
            let speed = i <= 12 ? Double(i) : i <= 37 ? 12 : max(0, 12 - Double(i - 37))
            let event = sample(Double(t), speed)
            let output = try replay.consume(event)
            let update = live.consume(event, acceptedSpeed: output.result == .accepted)
            if let candidate = update.created { liveID = candidate.id }
            if let candidate = output.rail.created { replayID = candidate.id }
        }
        let id = try XCTUnwrap(liveID)
        XCTAssertEqual(id, replayID)
        var answer = ReplayEvent(receivedAt: 261)
        answer.railFeedback = RailArrivalFeedback(candidateID: id, answer: .denied)
        XCTAssertEqual(try replay.consume(answer).rail.resolved?.answer, .denied)
    }
}
