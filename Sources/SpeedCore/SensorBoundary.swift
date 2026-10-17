import Foundation

public enum SensorInputError: Error { case invalidMountAxis }

/// Device-coordinate vector pointing toward the vehicle's direction of travel.
/// Valid only while the phone remains fixed in the calibrated mount.
public struct MountAxis: Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) throws {
        let length = hypot(hypot(x, y), z)
        guard length.isFinite, length > 1e-6 else { throw SensorInputError.invalidMountAxis }
        self.x = x/length; self.y = y/length; self.z = z/length
    }
    public func acceleration(x: Double, y: Double, z: Double) -> Double {
        (self.x*x + self.y*y + self.z*z) * 9.80665
    }
}

/// CLLocation timestamps use wall time; CoreMotion uses uptime.
/// A wall-clock adjustment discards that callback and requires resetting fusion.
public struct LocationClock: Sendable {
    private var offset: Double?
    public init() {}
    public mutating func convert(fixWallTime: Double, wallNow: Double, monotonicNow: Double) -> Double? {
        guard fixWallTime.isFinite, wallNow.isFinite, monotonicNow.isFinite else { return nil }
        let currentOffset = wallNow - monotonicNow
        if let offset, abs(offset - currentOffset) > 1 {
            self.offset = currentOffset
            return nil
        }
        if offset == nil { offset = currentOffset }
        return fixWallTime - offset!
    }
}

/// Conservative mount check: a 10° orientation change invalidates the axis until reset.
/// Vehicle turns can disable assistance too; location-only measurement remains available.
public struct MountMonitor: Sendable {
    private var reference: [Double]?
    private var invalidated = false
    public init() {}
    public mutating func accepts(x: Double, y: Double, z: Double, w: Double) -> Bool {
        guard !invalidated else { return false }
        let values = [x,y,z,w]
        let length = sqrt(values.reduce(0) { $0 + $1*$1 })
        guard length.isFinite, abs(length - 1) < 0.01 else { invalidated = true; return false }
        let normalized = values.map { $0 / length }
        guard let reference else { self.reference = normalized; return true }
        let dot = abs(zip(reference, normalized).reduce(0) { $0 + $1.0*$1.1 })
        if dot < cos(5 * .pi / 180) { invalidated = true }
        return !invalidated
    }
}
