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
    private var lastResult: IngestResult?
    private var lastInnovation: Double?
    private var lastNIS: Double?
    private var stationary = StationaryDetector()

    /// Shared by live capture and replay; invalid GPS velocity is never converted to zero.
    public mutating func observeStationaryEvidence(_ event: ReplayEvent) {
        stationary.consume(event)
    }

    public func diagnostics(at now: Double) -> FilterDiagnostics {
        var predicted = filter
        if let state = filter, now >= state.time { predicted?.predict(to: now) }
        let age = lastFix.map { max(0, now - $0.timestamp) }
        let base = lastFix.map { max(0.35, $0.speedAccuracy) }
        let growth = age.map { motionTrusted(at: now) ? hypot(0.35*$0, 0.12*$0*$0) : 0.75*$0*$0 }
        return FilterDiagnostics(stateTime: filter?.time, state: filter?.x, covariance: filter?.p,
            lastResult: lastResult, innovation: lastInnovation, nis: lastNIS,
            reportedSpeedAccuracy: lastFix?.speedAccuracy,
            uncertaintyFloor: base.flatMap { b in growth.map { hypot(b, $0) } },
            covarianceSpeedSigma: predicted.map { sqrt($0.p[0][0]) })
    }

    public init(mode: SensorMode = .handheld) { self.mode = mode }

    public mutating func reset() { self = SpeedEstimator(mode: mode) }

    @discardableResult
    public mutating func ingest(_ sample: SpeedObservation, receivedAt now: Double) -> IngestResult {
        stationary.observeSpeed(sample, at: now)
        let result = ingestSpeed(sample, receivedAt: now)
        lastResult = result
        return result
    }

    private mutating func ingestSpeed(_ sample: SpeedObservation, receivedAt now: Double) -> IngestResult {
        lastInnovation = nil; lastNIS = nil
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
        lastInnovation = innovation.residual
        lastNIS = innovation.residual*innovation.residual / innovation.variance
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
        let result = ingestMotion(sample, receivedAt: now)
        lastResult = result
        return result
    }

    private mutating func ingestMotion(_ sample: MotionObservation, receivedAt now: Double) -> IngestResult {
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
        if stationary.confirmed(at: now) {
            return SpeedEstimate(timestamp: now, speed: 0, uncertainty: nil, state: .predicted,
                                 source: .stationary, observationAge: stationary.positionAge(at: now))
        }
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

/// Infers a ground stop only from independent, current evidence. A quiet IMU alone
/// cannot distinguish a parked phone from a phone on a smooth, moving train.
private struct StationaryDetector: Sendable {
    private var source: ActivitySource = .waiting
    private var stationarySince: Double?
    private var quietSince: Double?
    private var lastMotionTime = -Double.infinity
    private var lastMotionReceipt = -Double.infinity
    private var lastPositionTime = -Double.infinity
    private var lastPositionReceipt = -Double.infinity
    private var anchor: (time: Double, latitude: Double, longitude: Double)?
    private var positionSpan = 0.0
    private var movingUntil = -Double.infinity
    private var groundStopConfirmed = false

    mutating func consume(_ event: ReplayEvent) {
        let now = event.receivedAt
        guard now.isFinite else { return }
        defer {
            if !groundEvidenceValid(at: now) { groundStopConfirmed = false }
            else if quietWindowReady { groundStopConfirmed = true }
        }
        if let value = event.activitySource {
            if value != .available { self = StationaryDetector() }
            source = value
        }
        if let activity = event.activity,
           activity.timestamp <= now + 0.05, now - activity.timestamp <= 1 {
            let stopped = source == .available && activity.confidence == .high && activity.stationary &&
                !activity.automotive && !activity.walking && !activity.running && !activity.cycling && !activity.unknown
            if stopped { if stationarySince == nil { stationarySince = now } }
            else { stationarySince = nil; quietSince = nil }
        }
        if let motion = event.rawMotion {
            let t = motion.timestamp ?? now
            if t.isFinite, t > lastMotionTime {
                let timely = t <= now + 0.05 && now - t <= 0.25
                let quiet = norm(motion.acceleration) <= 0.08 && norm(motion.rotationRate) <= 0.35
                // Hand motion can break the entry window, but does not by itself
                // invalidate an established ground stop. Missing data still does.
                if !timely || t - lastMotionTime > 0.3 { groundStopConfirmed = false }
                if !norm(motion.acceleration).isFinite || !norm(motion.rotationRate).isFinite {
                    groundStopConfirmed = false
                }
                if !timely || !quiet { quietSince = nil }
                else if quietSince == nil || t - lastMotionTime > 0.3 { quietSince = t }
                lastMotionTime = t
                lastMotionReceipt = timely ? now : -.infinity
            }
        }
        if let speed = event.speed { observeSpeed(speed, at: now) }
        if let position = event.locationDetails {
            guard let t = event.speed?.timestamp, t.isFinite, t <= now + 0.05, now - t <= 2,
                  position.latitude.isFinite, abs(position.latitude) <= 90,
                  position.longitude.isFinite, abs(position.longitude) <= 180,
                  let accuracy = position.rawHorizontalAccuracy ?? event.speed?.horizontalAccuracy,
                  accuracy.isFinite, (0...25).contains(accuracy) else {
                anchor = nil; positionSpan = 0; lastPositionReceipt = -.infinity
                return
            }
            guard t > lastPositionTime else { return }
            if let old = anchor, t - lastPositionTime <= 20,
               distance(old.latitude, old.longitude, position.latitude, position.longitude) <= 6 {
                positionSpan = t - old.time
            } else {
                anchor = (t, position.latitude, position.longitude)
                positionSpan = 0
            }
            lastPositionTime = t; lastPositionReceipt = now
        }
    }

    mutating func observeSpeed(_ speed: SpeedObservation, at now: Double) {
        guard now.isFinite, speed.timestamp.isFinite, speed.timestamp <= now + 0.05,
              now - speed.timestamp <= 2, speed.speed.isFinite, (0.8...140).contains(speed.speed),
              speed.speedAccuracy.isFinite, (0...2).contains(speed.speedAccuracy),
              (0...50).contains(speed.horizontalAccuracy) else { return }
        movingUntil = now + 30
        groundStopConfirmed = false
        anchor = nil; positionSpan = 0
    }

    func positionAge(at now: Double) -> Double { max(0, now - lastPositionTime) }

    func confirmed(at now: Double) -> Bool {
        groundStopConfirmed && groundEvidenceValid(at: now)
    }

    private var quietWindowReady: Bool {
        guard let quietSince else { return false }
        return lastMotionTime - quietSince >= 3
    }

    private func groundEvidenceValid(at now: Double) -> Bool {
        guard now.isFinite, now >= movingUntil, source == .available,
              let stationarySince, now - stationarySince >= 3 else { return false }
        return now >= lastMotionTime && now - lastMotionTime <= 0.3 && now - lastMotionReceipt <= 0.3 &&
            positionSpan >= 5 && now - lastPositionTime <= 20 && now - lastPositionReceipt <= 20
    }

    private func norm(_ values: [Double]) -> Double {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return .infinity }
        return hypot(hypot(values[0], values[1]), values[2])
    }

    private func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let a = pow(sin((lat2-lat1)*radians/2), 2) + cos(lat1*radians)*cos(lat2*radians)*pow(sin((lon2-lon1)*radians/2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
    }
}
