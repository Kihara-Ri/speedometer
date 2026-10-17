import Foundation

/// One JSONL input line. A line with no observation is a clock tick.
/// Raw iOS motion is retained separately from optional projected acceleration.
public struct RawMotion: Codable, Sendable {
    public var acceleration: [Double]
    public var gravity: [Double]
    public var rotationRate: [Double]
    public var quaternion: [Double]
    public init(acceleration: [Double], gravity: [Double], rotationRate: [Double], quaternion: [Double]) {
        self.acceleration = acceleration; self.gravity = gravity
        self.rotationRate = rotationRate; self.quaternion = quaternion
    }
}
public struct ReplayEvent: Codable, Sendable {
    public var receivedAt: Double
    public var speed: SpeedObservation?
    public var motion: MotionObservation?
    public var rawMotion: RawMotion?
    public var activity: ActivityObservation?
    public var activitySource: ActivitySource?
    public var reset: Bool?
    public var resetSpeedOnly: Bool?
    public init(receivedAt: Double, speed: SpeedObservation? = nil, motion: MotionObservation? = nil,
                rawMotion: RawMotion? = nil, reset: Bool? = nil,
                activity: ActivityObservation? = nil, activitySource: ActivitySource? = nil, resetSpeedOnly: Bool? = nil) {
        self.receivedAt = receivedAt; self.speed = speed; self.motion = motion
        self.rawMotion = rawMotion; self.reset = reset
        self.activity = activity; self.activitySource = activitySource; self.resetSpeedOnly = resetSpeedOnly
    }
}
public extension ReplayEvent {
    static func decode(_ data: Data) throws -> ReplayEvent {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(ReplayEvent.self, from: data)
    }
}
public struct ReplayOutput: Codable, Sendable {
    public var result: IngestResult?
    public var estimate: SpeedEstimate
    public var travel: TravelEstimate
}
public enum ReplayError: Error { case nonMonotonicReceiptTime, ambiguousEvent }
public struct SpeedReplay: Sendable {
    private var estimator: SpeedEstimator
    private var travel = TravelModeRecognizer()
    private var lastTime = -Double.infinity
    public init(mode: SensorMode = .handheld) { estimator = SpeedEstimator(mode: mode) }
    public mutating func consume(_ event: ReplayEvent) throws -> ReplayOutput {
        guard event.receivedAt.isFinite, event.receivedAt >= lastTime else { throw ReplayError.nonMonotonicReceiptTime }
        let inputs = [event.speed != nil, event.motion != nil, event.activity != nil,
                      event.activitySource != nil, event.reset == true, event.resetSpeedOnly == true].filter { $0 }.count
        guard inputs <= 1 else { throw ReplayError.ambiguousEvent }
        lastTime = event.receivedAt
        if event.reset == true { estimator.reset(); travel.reset() }
        if event.resetSpeedOnly == true { estimator.reset() }
        if let source = event.activitySource { travel.setSource(source, at: event.receivedAt) }
        if let activity = event.activity { _ = travel.ingest(activity, receivedAt: event.receivedAt) }
        let result: IngestResult?
        if let speed = event.speed {
            result = estimator.ingest(speed, receivedAt: event.receivedAt)
            if result == .accepted { _ = travel.ingestSpeed(speed, receivedAt: event.receivedAt) }
        }
        else if let motion = event.motion { result = estimator.ingest(motion, receivedAt: event.receivedAt) }
        else { result = nil }
        return ReplayOutput(result: result, estimate: estimator.estimate(at: event.receivedAt), travel: travel.advance(to: event.receivedAt))
    }
}
