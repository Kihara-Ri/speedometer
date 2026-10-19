import Foundation

public enum SensorMode: String, Codable, Sendable { case handheld, mounted }
public enum EstimateState: String, Codable, Sendable { case measured, predicted, unavailable }
public enum EstimateSource: String, Codable, Sendable { case location, model, inertial, stationary, none }
public enum IngestResult: String, Codable, Sendable {
    case accepted, candidate, invalid, invalidTime, stale, outOfOrder, outlier, ignored, untrustedMotion
}

/// All timestamps are seconds on one monotonic clock. All speeds are m/s.
public struct SpeedObservation: Codable, Sendable {
    public var timestamp: Double
    public var speed: Double
    public var speedAccuracy: Double
    public var horizontalAccuracy: Double
    public init(timestamp: Double, speed: Double, speedAccuracy: Double, horizontalAccuracy: Double) {
        self.timestamp = timestamp; self.speed = speed
        self.speedAccuracy = speedAccuracy; self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Only provide vehicle-forward, gravity-removed acceleration, in m/s².
/// The iOS adapter requires an explicit fixed-mount axis to produce this input.
public struct MotionObservation: Codable, Sendable {
    public var timestamp: Double
    public var acceleration: Double
    public var rotationRate: Double
    public init(timestamp: Double, acceleration: Double, rotationRate: Double) {
        self.timestamp = timestamp; self.acceleration = acceleration; self.rotationRate = rotationRate
    }
}

public struct SpeedEstimate: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var speed: Double?
    /// Model uncertainty scale in m/s, NOT a calibrated statistical confidence interval.
    public var uncertainty: Double?
    public var state: EstimateState
    public var source: EstimateSource
    public var observationAge: Double?
    public var kilometersPerHour: Double? { speed.map { $0 * 3.6 } }
}
