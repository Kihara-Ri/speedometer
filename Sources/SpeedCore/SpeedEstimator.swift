import Foundation

/// Single-owner value type; serialize all ingestion on one executor.
/// estimate(at:) never mutates the filter, so render cadence cannot change results.
public struct SpeedEstimator: Sendable {
    public let mode: SensorMode
    private var filter: KalmanState?
    private var lastFix: SpeedObservation?
    private var lastGNSSInput = -Double.infinity
    private var lastMotionInput = -Double.infinity
    private var candidate: SpeedObservation?
    private var candidateCount = 0
    private var lastMotion: Double?
    private var motionStart: Double?
    private var motionBlockedUntil = -Double.infinity

    public init(mode: SensorMode = .handheld) { self.mode = mode }

    public mutating func reset() { self = SpeedEstimator(mode: mode) }

    @discardableResult
    public mutating func ingest(_ sample: SpeedObservation, receivedAt now: Double) -> IngestResult {
        guard now.isFinite, sample.timestamp.isFinite, sample.timestamp <= now + 0.05 else { return .invalidTime }
        guard now - sample.timestamp <= 2 else { return .stale }
        guard sample.speed.isFinite, (0...140).contains(sample.speed),
              sample.speedAccuracy.isFinite, (0...5).contains(sample.speedAccuracy),
              sample.horizontalAccuracy.isFinite, (0...100).contains(sample.horizontalAccuracy) else { return .invalid }
        guard sample.timestamp > lastGNSSInput else { return .outOfOrder }
        guard filter == nil || now >= filter!.time else { return .outOfOrder }
        lastGNSSInput = sample.timestamp

        if let last = lastFix, now - last.timestamp > (motionTrusted(at: now) ? 6 : 3) {
            filter = nil; lastFix = nil; candidate = nil; candidateCount = 0
            invalidateMotion(at: now)
        }
        guard var predicted = filter, let last = lastFix else {
            return capture(sample, now: now, confirmations: 2)
        }
        predicted.predict(to: now)
        let sigma = max(0.35, sample.speedAccuracy)
        let lag = max(0, now - sample.timestamp)
        let variance = sigma*sigma + 4*lag*lag
        let value = max(0, sample.speed + predicted.x[1]*lag)
        var innovation = predicted.innovation(value, h: [1,0,0], variance: variance)
        let elapsed = sample.timestamp - last.timestamp
        let physicallyPossible = abs(sample.speed - last.speed) <= 12*elapsed + 3*hypot(sigma, max(0.35, last.speedAccuracy))
        // Cruise uses a quiet process model. A plausible maneuver raises process noise,
        // preserving braking response without extrapolating ordinary GNSS jitter.
        if physicallyPossible, abs(innovation.residual) > 2.5, var maneuver = filter {
            maneuver.predict(to: now, jerkNoise: 4)
            predicted = maneuver
            innovation = predicted.innovation(value, h: [1,0,0], variance: variance)
        }
        let consistent = innovation.residual*innovation.residual / innovation.variance <= 25
        if !physicallyPossible || !consistent {
            // New regime must persist across 3 high-quality fixes. Never let one spike rebase the filter.
            if sample.speedAccuracy <= 1 {
                let result = capture(sample, now: now, confirmations: 3)
                if result == .accepted { return result }
            } else { candidate = nil; candidateCount = 0 }
            return .outlier
        }
        predicted.update(value, h: [1,0,0], variance: variance)
        filter = predicted; lastFix = sample
        candidate = nil; candidateCount = 0
        return .accepted
    }

    @discardableResult
    public mutating func ingest(_ sample: MotionObservation, receivedAt now: Double) -> IngestResult {
        guard mode == .mounted else { return .ignored }
        guard now.isFinite, sample.timestamp.isFinite, sample.timestamp <= now + 0.05 else { return .invalidTime }
        guard now - sample.timestamp <= 0.25 else { return .stale }
        guard sample.acceleration.isFinite, abs(sample.acceleration) <= 15,
              sample.rotationRate.isFinite, sample.rotationRate >= 0 else { return .invalid }
        guard sample.timestamp > lastMotionInput else { return .outOfOrder }
        let gap = sample.timestamp - lastMotionInput
        lastMotionInput = sample.timestamp
        guard sample.rotationRate <= 0.25 else {
            invalidateMotion(at: now, mountMoved: true); return .untrustedMotion
        }
        if gap > 0.3 { motionStart = nil }
        guard now >= motionBlockedUntil, var state = filter, let fix = lastFix,
              now >= state.time, now - fix.timestamp <= 6 else { return .untrustedMotion }
        if motionStart == nil { motionStart = sample.timestamp }
        state.predict(to: now)
        // Includes vibration/noise; bias is estimated jointly against GNSS speed changes.
        state.update(sample.acceleration, h: [0,1,1], variance: 0.36)
        filter = state; lastMotion = now
        return .accepted
    }

    public func estimate(at now: Double) -> SpeedEstimate {
        guard now.isFinite, let state = filter, let fix = lastFix, now >= state.time else {
            return unavailable(now, age: nil)
        }
        let age = max(0, now - fix.timestamp)
        let inertial = motionTrusted(at: now)
        let horizon = inertial ? 6.0 : 3.0
        guard age <= horizon else { return unavailable(now, age: age) }
        var predicted = state
        predicted.predict(to: now)
        // Deliberate floor for unobserved acceleration / correlated IMU bias.
        // Raw OS accuracies and our Gaussian model have not been field-calibrated.
        let base = max(0.35, fix.speedAccuracy)
        let growth = inertial ? hypot(0.35*age, 0.12*age*age) : 0.75*age*age
        let uncertainty = max(sqrt(predicted.p[0][0]), hypot(base, growth))
        guard uncertainty.isFinite, uncertainty <= 8, predicted.x[0].isFinite else { return unavailable(now, age: age) }
        return SpeedEstimate(timestamp: now, speed: min(140, max(0, predicted.x[0])),
                             uncertainty: uncertainty, state: age <= 1 ? .measured : .predicted,
                             source: age <= 1 ? .location : (inertial ? .inertial : .model), observationAge: age)
    }

    private func motionTrusted(at now: Double) -> Bool {
        guard mode == .mounted, let lastMotion, let motionStart, let state = filter else { return false }
        return now - lastMotion <= 0.25 && lastMotion - motionStart >= 8 &&
               now >= motionBlockedUntil && sqrt(state.p[2][2]) <= 0.3
    }

    private mutating func invalidateMotion(at now: Double, mountMoved: Bool = false) {
        lastMotion = nil; motionStart = nil
        if mountMoved { motionBlockedUntil = .infinity }
        // Do not keep bias learned before a mount orientation change.
        if filter != nil {
            filter!.x[1] = 0
            filter!.p[1][1] = max(9, filter!.p[1][1])
            filter!.x[2] = 0
            filter!.p[2][2] = 0.25
            for i in 0..<2 { filter!.p[i][2] = 0; filter!.p[2][i] = 0 }
        }
    }

    private mutating func capture(_ sample: SpeedObservation, now: Double, confirmations: Int) -> IngestResult {
        if let previous = candidate,
           sample.timestamp - previous.timestamp >= 0.2,
           sample.timestamp - previous.timestamp <= 2.5,
           abs(sample.speed - previous.speed) <= 12*(sample.timestamp - previous.timestamp) + 1 {
            candidateCount += 1
        } else { candidateCount = 1 }
        let previous = candidate
        candidate = sample
        guard candidateCount >= confirmations else { return .candidate }
        let dt = sample.timestamp - (previous?.timestamp ?? sample.timestamp)
        let acceleration = dt > 0 ? min(12, max(-12, (sample.speed - (previous?.speed ?? sample.speed))/dt)) : 0
        let lag = max(0, now - sample.timestamp)
        filter = KalmanState(speed: max(0, sample.speed + acceleration*lag), acceleration: acceleration,
                             variance: pow(max(0.35, sample.speedAccuracy), 2) + 4*lag*lag, time: now)
        lastFix = sample; candidate = nil; candidateCount = 0
        lastMotion = nil; motionStart = nil
        return .accepted
    }

    private func unavailable(_ now: Double, age: Double?) -> SpeedEstimate {
        SpeedEstimate(timestamp: now.isFinite ? now : 0, speed: nil, uncertainty: nil,
                      state: .unavailable, source: .none, observationAge: age)
    }
}
