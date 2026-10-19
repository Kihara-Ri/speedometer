import Foundation

/// Integrates only adjacent, available observations. Missing data never means zero speed.
public struct DistanceAccumulator: Sendable {
    public private(set) var meters = 0.0
    public private(set) var coveredSeconds = 0.0
    public private(set) var movingSeconds = 0.0
    private var previous: SpeedEstimate?
    private var lastTime = -Double.infinity
    public init() {}
    public mutating func breakContinuity() { previous = nil }
    public mutating func ingest(_ estimate: SpeedEstimate) {
        guard estimate.timestamp.isFinite, estimate.timestamp >= lastTime else { return }
        lastTime = estimate.timestamp
        guard estimate.state != .unavailable, let speed = estimate.speed, speed.isFinite, speed >= 0 else {
            previous = nil; return
        }
        if let previous, let oldSpeed = previous.speed {
            let dt = estimate.timestamp - previous.timestamp
            if dt > 0, dt <= 1 {
                meters += (oldSpeed + speed) * 0.5 * dt
                coveredSeconds += dt
                if (oldSpeed + speed) * 0.5 > 0.5 { movingSeconds += dt }
            }
        }
        previous = estimate
    }
}

public struct RecordingMarker: Codable, Sendable {
    public var id: String
    public var kind: String
    public var note: String
    public var timestamp: Double?
    public var candidateID: String?
    public init(id: String, kind: String, note: String, timestamp: Double? = nil, candidateID: String? = nil) {
        self.id = id; self.kind = kind; self.note = note
        self.timestamp = timestamp; self.candidateID = candidateID
    }
}

/// Values retain OS units: raw acceleration in g, gyro in rad/s, magnetic field in µT.
public struct VectorSample: Codable, Sendable {
    public var timestamp: Double
    public var values: [Double]
    public init(timestamp: Double, values: [Double]) { self.timestamp = timestamp; self.values = values }
}

public struct LocationDetails: Codable, Sendable {
    public var wallTime: Double
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var verticalAccuracy: Double
    public var course: Double
    public var courseAccuracy: Double
    public var simulated: Bool?
    public var accessory: Bool?
    public var rawSpeed: Double?
    public var rawSpeedAccuracy: Double?
    public var rawHorizontalAccuracy: Double?
    public init(wallTime: Double, latitude: Double, longitude: Double, altitude: Double,
                verticalAccuracy: Double, course: Double, courseAccuracy: Double,
                simulated: Bool?, accessory: Bool?, rawSpeed: Double? = nil,
                rawSpeedAccuracy: Double? = nil, rawHorizontalAccuracy: Double? = nil) {
        self.wallTime = wallTime; self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude; self.verticalAccuracy = verticalAccuracy
        self.course = course; self.courseAccuracy = courseAccuracy
        self.simulated = simulated; self.accessory = accessory
        self.rawSpeed = rawSpeed; self.rawSpeedAccuracy = rawSpeedAccuracy
        self.rawHorizontalAccuracy = rawHorizontalAccuracy
    }
}

public struct FilterDiagnostics: Codable, Sendable {
    public var stateTime: Double?
    public var state: [Double]?
    public var covariance: [[Double]]?
    public var lastResult: IngestResult?
    public var innovation: Double?
    public var nis: Double?
    public var reportedSpeedAccuracy: Double?
    public var uncertaintyFloor: Double?
    public var covarianceSpeedSigma: Double?
}

/// Serial disk queue keeps file writes away from sensor callbacks, retaining submission order.
public final class SensorJournal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "speedometer.sensor-journal", qos: .utility)
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var failure: (any Error)?
    private var closed = false
    private let onFailure: @Sendable (String) -> Void

    public init(url: URL, onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic exclusive creation: a session must never overwrite or append to another session.
        #if os(iOS)
        try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data().write(to: url, options: .withoutOverwriting)
        #endif
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        self.onFailure = onFailure
    }

    public func append(_ event: ReplayEvent) {
        queue.async { [self] in
            guard failure == nil, !closed else { return }
            do {
                var line = try encoder.encode(event); line.append(10)
                try handle.write(contentsOf: line)
            } catch { failure = error; onFailure(String(describing: error)) }
        }
    }

    public func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                if !closed {
                    do { try handle.synchronize() }
                    catch { if failure == nil { failure = error } }
                    do { try handle.close() }
                    catch { if failure == nil { failure = error } }
                    closed = true
                }
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            }
        }
    }
}
