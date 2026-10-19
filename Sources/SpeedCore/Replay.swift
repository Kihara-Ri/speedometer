import Foundation

/// One JSONL input line. A line with no observation is a clock tick.
/// Raw iOS motion is retained separately from optional projected acceleration.
public struct RawMotion: Codable, Sendable {
    public var timestamp: Double?
    public var acceleration: [Double]
    public var gravity: [Double]
    public var rotationRate: [Double]
    public var quaternion: [Double]
    public init(acceleration: [Double], gravity: [Double], rotationRate: [Double], quaternion: [Double], timestamp: Double? = nil) {
        self.timestamp = timestamp
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
    public var wallTime: Double?
    public var metadata: [String: String]?
    public var marker: RecordingMarker?
    public var lifecycle: String?
    public var sensorError: String?
    public var locationDetails: LocationDetails?
    public var accelerometer: VectorSample?
    public var gyroscope: VectorSample?
    public var magnetometer: VectorSample?
    public var relativeAltitude: Double?
    public var pressure: Double?
    public var altitudeTimestamp: Double?
    public var recordedEstimate: SpeedEstimate?
    public var diagnostics: FilterDiagnostics?
    public var batteryLevel: Float?
    public var thermalState: Int?
    public var railFeedback: RailArrivalFeedback?
    public var railCandidate: RailArrivalCandidate?
    public var railResolution: RailArrivalResolution?
    public init(receivedAt: Double, speed: SpeedObservation? = nil, motion: MotionObservation? = nil,
                rawMotion: RawMotion? = nil, reset: Bool? = nil,
                activity: ActivityObservation? = nil, activitySource: ActivitySource? = nil, resetSpeedOnly: Bool? = nil,
                marker: RecordingMarker? = nil) {
        self.receivedAt = receivedAt; self.speed = speed; self.motion = motion
        self.rawMotion = rawMotion; self.reset = reset
        self.activity = activity; self.activitySource = activitySource; self.resetSpeedOnly = resetSpeedOnly
        self.marker = marker
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
    public var rail: RailArrivalUpdate
}
public enum ReplayError: Error { case nonMonotonicReceiptTime, ambiguousEvent }
public struct SpeedReplay: Sendable {
    private var estimator: SpeedEstimator
    private var travel = TravelModeRecognizer()
    private var rail = RailArrivalRecognizer()
    private var lastTime = -Double.infinity
    public init(mode: SensorMode = .handheld) { estimator = SpeedEstimator(mode: mode) }
    public mutating func consume(_ event: ReplayEvent) throws -> ReplayOutput {
        guard event.receivedAt.isFinite, event.receivedAt >= lastTime else { throw ReplayError.nonMonotonicReceiptTime }
        let inputs = [event.speed != nil, event.motion != nil, event.activity != nil,
                      event.activitySource != nil, event.reset == true, event.resetSpeedOnly == true,
                      event.railFeedback != nil].filter { $0 }.count
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
        estimator.observeStationaryEvidence(event)
        return ReplayOutput(result: result, estimate: estimator.estimate(at: event.receivedAt),
                            travel: travel.advance(to: event.receivedAt),
                            rail: rail.consume(event, acceptedSpeed: result == .accepted))
    }
}
