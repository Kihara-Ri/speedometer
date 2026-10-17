import Foundation

public enum TravelMode: String, Codable, Sendable { case vehicle, independent, unknown }
public enum ActivityConfidence: String, Codable, Sendable { case low, medium, high }
public enum ActivitySource: String, Codable, Sendable { case waiting, available, denied, restricted, unavailable, stopped }
public enum TravelReason: String, Codable, Sendable {
    case waitingForActivity, sourceUnavailable, sourceDenied, stopped, confirming, activity,
         stationaryContext, stationaryAmbiguous, lowConfidence, unknownActivity,
         conflictingActivity, speedConflict, exitUnconfirmed, invalidTime
}

/// Event-driven system activity. timestamp is callback receipt uptime, NOT activity.startDate.
/// An unchanged activity remains active until another event or source/lifecycle reset.
public struct ActivityObservation: Codable, Sendable {
    public var timestamp: Double
    public var confidence: ActivityConfidence
    public var automotive: Bool
    public var walking: Bool
    public var running: Bool
    public var cycling: Bool
    public var stationary: Bool
    public var unknown: Bool
    public var startedAtWallTime: Double?
    public init(timestamp: Double, confidence: ActivityConfidence, automotive: Bool = false,
                walking: Bool = false, running: Bool = false, cycling: Bool = false,
                stationary: Bool = false, unknown: Bool = false, startedAtWallTime: Double? = nil) {
        self.timestamp = timestamp; self.confidence = confidence; self.automotive = automotive
        self.walking = walking; self.running = running; self.cycling = cycling
        self.stationary = stationary; self.unknown = unknown; self.startedAtWallTime = startedAtWallTime
    }
}
public struct TravelEstimate: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var mode: TravelMode
    public var confidence: ActivityConfidence
    public var reason: TravelReason
    public var source: ActivitySource
    public var pendingMode: TravelMode?
    public var stationary: Bool
    public var cycling: Bool
}

/// Classifies transport independently from phone mounting and speed estimation.
/// Confidence labels are qualitative evidence labels, not calibrated probabilities.
public struct TravelModeRecognizer: Sendable {
    private var source: ActivitySource = .waiting
    private var activity: ActivityObservation?
    private var speed: SpeedObservation?
    private var lastTime = -Double.infinity
    private var lastActivityTime = -Double.infinity
    private var confirmed: TravelMode = .unknown
    private var candidate: TravelMode?
    private var candidateSince: Double?

    public init() {}
    public mutating func reset() { self = TravelModeRecognizer() }

    public mutating func setSource(_ value: ActivitySource, at now: Double) {
        guard now.isFinite, now >= lastTime else { return }
        if value != source {
            activity = nil; speed = nil; confirmed = .unknown; candidate = nil
            lastActivityTime = -Double.infinity
        }
        source = value; lastTime = now
    }

    @discardableResult
    public mutating func ingest(_ input: ActivityObservation, receivedAt now: Double) -> Bool {
        guard source == .available, now.isFinite, input.timestamp.isFinite,
              now >= lastTime, input.timestamp <= now + 0.05,
              now - input.timestamp <= 1, input.timestamp > lastActivityTime else { return false }
        lastActivityTime = input.timestamp
        activity = input
        let proposed = proposedMode(input)
        if proposed != candidate {
            candidate = proposed
            // Do not count native startDate: it can predate this session by hours.
            candidateSince = now
        }
        lastTime = now
        return true
    }

    /// Only feed accepted location speed; predictions must not create circular evidence.
    @discardableResult
    public mutating func ingestSpeed(_ input: SpeedObservation, receivedAt now: Double) -> Bool {
        guard now.isFinite, now >= lastTime, input.timestamp.isFinite,
              input.timestamp <= now + 0.05, now - input.timestamp <= 1.5,
              input.speed.isFinite, (0...140).contains(input.speed),
              input.speedAccuracy.isFinite, (0...1.5).contains(input.speedAccuracy),
              input.horizontalAccuracy.isFinite, (0...50).contains(input.horizontalAccuracy),
              speed == nil || input.timestamp > speed!.timestamp else { return false }
        speed = input; lastTime = now
        return true
    }

    public mutating func advance(to now: Double) -> TravelEstimate {
        guard now.isFinite, now >= lastTime else { return output(now.isFinite ? now : 0, .unknown, .low, .invalidTime) }
        lastTime = now
        guard source == .available else {
            let reason: TravelReason
            switch source {
            case .denied, .restricted: reason = .sourceDenied
            case .unavailable: reason = .sourceUnavailable
            case .stopped: reason = .stopped
            default: reason = .waitingForActivity
            }
            return output(now, .unknown, .low, reason)
        }
        guard let activity else { return output(now, .unknown, .low, .waitingForActivity) }
        let human = activity.walking || activity.running || activity.cycling
        if activity.automotive && human { return output(now, .unknown, .low, .conflictingActivity) }
        if activity.unknown { return output(now, .unknown, .low, .unknownActivity) }
        if activity.confidence == .low {
            return output(now, now - activity.timestamp <= 8 ? confirmed : .unknown, .low, .lowConfidence)
        }
        guard let proposed = proposedMode(activity) else {
            if activity.stationary {
                let retained = now - activity.timestamp <= 120 ? confirmed : .unknown
                return output(now, retained, retained == .unknown ? .low : .medium,
                              retained == .unknown ? .stationaryAmbiguous : .stationaryContext)
            }
            return output(now, .unknown, .low, .unknownActivity)
        }
        let freshSpeed = speed.flatMap { now - $0.timestamp <= 1.5 ? $0 : nil }
        if proposed == .independent, !activity.cycling, let freshSpeed {
            let limit = activity.running ? 12.0 : 4.5
            if freshSpeed.speed - 2*max(0.35, freshSpeed.speedAccuracy) > limit {
                candidateSince = nil
                return output(now, .unknown, .low, .speedConflict)
            }
        }
        // Walking down a train aisle is not proof of leaving the train.
        if confirmed == .vehicle, proposed == .independent, !activity.cycling, freshSpeed == nil {
            candidateSince = nil
            return output(now, now - activity.timestamp <= 30 ? .vehicle : .unknown, .low, .exitUnconfirmed)
        }
        if proposed == confirmed { return output(now, confirmed, activity.confidence, .activity) }
        if candidateSince == nil { candidateSince = now }
        let wait = confirmed == .vehicle && proposed == .independent ? 5.0 : (activity.confidence == .high ? 2.0 : 4.0)
        guard now - candidateSince! >= wait else { return output(now, confirmed, .low, .confirming, pending: proposed) }
        confirmed = proposed
        return output(now, confirmed, activity.confidence, .activity)
    }

    private func proposedMode(_ value: ActivityObservation) -> TravelMode? {
        guard !value.unknown, value.confidence != .low else { return nil }
        let human = value.walking || value.running || value.cycling
        guard !(value.automotive && human) else { return nil }
        if value.automotive { return .vehicle }
        if human { return .independent }
        return nil
    }
    private func output(_ now: Double, _ mode: TravelMode, _ confidence: ActivityConfidence,
                        _ reason: TravelReason, pending: TravelMode? = nil) -> TravelEstimate {
        TravelEstimate(timestamp: now, mode: mode, confidence: confidence, reason: reason,
                       source: source, pendingMode: pending, stationary: activity?.stationary ?? false,
                       cycling: activity?.cycling ?? false)
    }
}
