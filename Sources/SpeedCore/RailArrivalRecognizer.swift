import Foundation

public enum RailArrivalAnswer: String, Codable, Sendable { case confirmed, denied, unanswered }
public enum RailArrivalEndReason: String, Codable, Sendable {
    case responded, expired, resumed, dataLost, reset, recordingEnded, humanActivity
}
public struct RailArrivalFeedback: Codable, Sendable {
    public var candidateID: String
    public var answer: RailArrivalAnswer
    public init(candidateID: String, answer: RailArrivalAnswer) {
        self.candidateID = candidateID; self.answer = answer
    }
}
public struct RailArrivalCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var algorithmID: String
    public var evidenceStartedAt: Double
    public var stoppedAt: Double
    public var detectedAt: Double
    public var peakSpeed: Double
    public var brakingSeconds: Double
    public var completedRuns: Int
}
public struct RailArrivalResolution: Codable, Sendable {
    public var candidateID: String
    public var timestamp: Double
    public var stoppedAt: Double
    public var answer: RailArrivalAnswer
    public var reason: RailArrivalEndReason
}
public struct RailArrivalUpdate: Codable, Sendable {
    public var current: RailArrivalCandidate?
    public var created: RailArrivalCandidate?
    public var resolved: RailArrivalResolution?
    public var isRailLike: Bool
}

/// Experimental sequence heuristic, not a calibrated train/road classifier.
/// No speed integration, route inference, or automatic learning from individual answers.
public struct RailArrivalRecognizer: Sendable {
    public static let algorithmID = "rail-stop-v2-2026-10-22"
    private enum Limits {
        // sampleGap tolerates one missing 1 Hz fix plus delivery lag; contextGap is too short to hide a whole stop.
        static let sampleGap = 3.0, contextGap = 10.0, maxAge = 1.5, stopSpeedUpper = 0.8
        static let cruiseSpeed = 8.0, cruiseSeconds = 15.0, minPeak = 10.0
        static let brakingSeconds = 6.0, minDrop = 7.0, stopSeconds = 4.0
        static let maxBrakePlateau = 2.0
        static let quietSeconds = 3.0, motionAge = 1.0, promptSeconds = 30.0
        static let minRunSeconds = 25.0, minCycleSeconds = 40.0, maxCycleSeconds = 600.0
    }
    private var lastTime = -Double.infinity
    private var lastSpeed: SpeedObservation?
    private var lastSpeedTime = -Double.infinity
    private var lastMotionTime = -Double.infinity
    private var quietSince: Double?
    private var humanActivity = false
    private var runStart: Double?
    private var cruiseSince: Double?
    private var armed = false
    private var peak = 0.0
    private var brakingSince: Double?
    private var lastDeceleration: Double?
    private var stopSince: Double?
    private var cycleConsumed = false
    private var completedRuns = 0
    private var lastStop: Double?
    private var contextStartedAt: Double?
    private var current: RailArrivalCandidate?

    public init() {}

    /// acceptedSpeed must reflect the speed filter's result in both live and replay callers.
    public mutating func consume(_ event: ReplayEvent, acceptedSpeed: Bool = true) -> RailArrivalUpdate {
        let now = event.receivedAt
        guard now.isFinite, now >= lastTime else { return output() }
        lastTime = now
        var resolution: RailArrivalResolution?
        if event.reset == true || event.resetSpeedOnly == true || event.lifecycle == "recordingEnded" || event.lifecycle == "recordingStopping" {
            let ended = event.lifecycle == "recordingEnded" || event.lifecycle == "recordingStopping"
            resolution = close(at: now, reason: ended ? .recordingEnded : .reset)
            clearEvidence()
            quietSince = nil; lastMotionTime = -.infinity
            if event.reset == true { humanActivity = false }
            return output(resolved: resolution)
        }
        if let activity = event.activity, activity.timestamp.isFinite,
           activity.timestamp <= now + 0.05, now - activity.timestamp <= 1,
           activity.confidence != .low {
            humanActivity = activity.walking || activity.running || activity.cycling
            if humanActivity {
                resolution = close(at: now, reason: .humanActivity)
                clearEvidence()
            }
        }
        if let source = event.activitySource, source != .available { humanActivity = false }
        if let raw = event.rawMotion { ingestMotion(raw, at: now) }

        // Clock ticks cannot extend a single low-speed sample into a sustained stop.
        // A short outage only breaks the current run; a long one may hide a whole stop, so it breaks the context too.
        if let speed = lastSpeed, now - speed.timestamp > Limits.sampleGap {
            resolution = close(at: now, reason: .dataLost) ?? resolution
            clearRun(); lastSpeed = nil
        }
        if now - lastSpeedTime > Limits.contextGap { clearContext() }
        if let stop = lastStop, now - stop > Limits.maxCycleSeconds { clearContext() }
        if let candidate = current, now - candidate.detectedAt >= Limits.promptSeconds {
            resolution = close(at: now, reason: .expired) ?? resolution
        }

        var created: RailArrivalCandidate?
        if let speed = event.speed {
            if humanActivity {
                resolution = close(at: now, reason: .humanActivity) ?? resolution
                clearEvidence()
                return output(resolved: resolution)
            }
            // An isolated bad fix is skipped; if bad fixes persist, the sample gap above breaks the run.
            guard acceptedSpeed, valid(speed, at: now) else { return output(resolved: resolution) }
            if let previous = lastSpeed, speed.timestamp <= previous.timestamp {
                return output(resolved: resolution)
            }
            if speed.speed > 2 {
                resolution = close(at: now, reason: .resumed) ?? resolution
                if cycleConsumed { clearRun() }
                if runStart == nil { runStart = speed.timestamp }
            }
            if let previous = lastSpeed {
                let dt = speed.timestamp - previous.timestamp
                let change = (speed.speed - previous.speed) / dt
                // Compared against the last plausible sample, so a single spike cannot also reject its successor.
                if change < -2.5 || change > 3.0 { return output(resolved: resolution) }
                if armed, speed.speed < peak - 0.5, change < -0.15 {
                    if brakingSince == nil { brakingSince = previous.timestamp }
                    lastDeceleration = speed.timestamp
                } else if change > 0.3 {
                    brakingSince = nil; lastDeceleration = nil; stopSince = nil
                } else if speed.speed + speed.speedAccuracy > Limits.stopSpeedUpper,
                          let lastDeceleration, speed.timestamp - lastDeceleration > Limits.maxBrakePlateau {
                    brakingSince = nil; self.lastDeceleration = nil
                }
            }
            peak = max(peak, speed.speed)
            if speed.speed - speed.speedAccuracy >= Limits.cruiseSpeed {
                if cruiseSince == nil { cruiseSince = speed.timestamp }
                if speed.timestamp - cruiseSince! >= Limits.cruiseSeconds { armed = true }
            } else if !armed { cruiseSince = nil }

            let stopped = speed.speed + speed.speedAccuracy <= Limits.stopSpeedUpper
            if stopped {
                if stopSince == nil { stopSince = speed.timestamp }
            } else { stopSince = nil }
            if !cycleConsumed, armed, let start = runStart, let brake = brakingSince, let stop = stopSince,
               stop - start >= Limits.minRunSeconds, peak >= Limits.minPeak,
               peak - speed.speed >= Limits.minDrop, stop - brake >= Limits.brakingSeconds,
               speed.timestamp - stop >= Limits.stopSeconds,
               now - lastMotionTime <= Limits.motionAge,
               let quietSince, speed.timestamp - quietSince >= Limits.quietSeconds {
                cycleConsumed = true
                if let previousStop = lastStop, stop - previousStop >= Limits.minCycleSeconds,
                   stop - previousStop <= Limits.maxCycleSeconds { completedRuns += 1 }
                else { completedRuns = 1; contextStartedAt = start }
                lastStop = stop
                if completedRuns >= 2 {
                    // Replaying a later recording alone must retain the live candidate identity.
                    let candidate = RailArrivalCandidate(id: "rail-\(stop)", algorithmID: Self.algorithmID,
                        evidenceStartedAt: contextStartedAt ?? start, stoppedAt: stop, detectedAt: now, peakSpeed: peak,
                        brakingSeconds: stop - brake, completedRuns: completedRuns)
                    current = candidate; created = candidate
                }
            }
            lastSpeed = speed; lastSpeedTime = speed.timestamp
        }
        if let feedback = event.railFeedback, feedback.answer != .unanswered,
           current?.id == feedback.candidateID {
            resolution = close(at: now, reason: .responded, answer: feedback.answer) ?? resolution
        }
        return output(created: created, resolved: resolution)
    }

    private func valid(_ speed: SpeedObservation, at now: Double) -> Bool {
        speed.timestamp.isFinite && speed.timestamp <= now + 0.05 && now - speed.timestamp <= Limits.maxAge &&
        speed.speed.isFinite && (0...140).contains(speed.speed) &&
        speed.speedAccuracy.isFinite && (0...1).contains(speed.speedAccuracy) &&
        speed.horizontalAccuracy.isFinite && (0...35).contains(speed.horizontalAccuracy)
    }
    private mutating func ingestMotion(_ raw: RawMotion, at now: Double) {
        guard let t = raw.timestamp, t.isFinite, t > lastMotionTime, t <= now + 0.05,
              now - t <= Limits.motionAge, raw.acceleration.count == 3, raw.rotationRate.count == 3,
              raw.acceleration.allSatisfy(\.isFinite), raw.rotationRate.allSatisfy(\.isFinite) else {
            quietSince = nil; return
        }
        if t - lastMotionTime > Limits.motionAge { quietSince = nil }
        lastMotionTime = t
        let acceleration = sqrt(raw.acceleration.reduce(0) { $0 + $1 * $1 })
        let rotation = sqrt(raw.rotationRate.reduce(0) { $0 + $1 * $1 })
        if rotation > 0.6 {
            // Rotation invalidates this braking sequence; quietness later cannot resurrect it.
            brakingSince = nil; lastDeceleration = nil; armed = false; cruiseSince = nil
        }
        if acceleration <= 0.06, rotation <= 0.2 {
            if quietSince == nil { quietSince = t }
        } else { quietSince = nil }
    }
    private mutating func close(at now: Double, reason: RailArrivalEndReason,
                                answer: RailArrivalAnswer = .unanswered) -> RailArrivalResolution? {
        guard let candidate = current else { return nil }
        current = nil
        return RailArrivalResolution(candidateID: candidate.id, timestamp: now, stoppedAt: candidate.stoppedAt,
                                     answer: answer, reason: reason)
    }
    private mutating func clearRun() {
        runStart = nil; cruiseSince = nil; armed = false; peak = 0
        brakingSince = nil; lastDeceleration = nil; stopSince = nil; cycleConsumed = false
    }
    private mutating func clearContext() {
        completedRuns = 0; lastStop = nil; contextStartedAt = nil
    }
    private mutating func clearEvidence() {
        clearRun(); clearContext(); lastSpeed = nil; lastSpeedTime = -.infinity
    }
    private func output(created: RailArrivalCandidate? = nil,
                        resolved: RailArrivalResolution? = nil) -> RailArrivalUpdate {
        RailArrivalUpdate(current: current, created: created, resolved: resolved, isRailLike: completedRuns >= 2)
    }
}
