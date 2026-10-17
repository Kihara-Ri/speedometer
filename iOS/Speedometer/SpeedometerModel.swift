import UIKit
import Observation
#if canImport(SpeedCore)
import SpeedCore
#endif

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh, ms, mph
    var id: String { rawValue }

    var label: String {
        switch self { case .kmh: "km/h"; case .ms: "m/s"; case .mph: "mph" }
    }
    /// Multiplier from m/s.
    var factor: Double {
        switch self { case .kmh: 3.6; case .ms: 1; case .mph: 2.2369362921 }
    }
    var decimals: Int { self == .ms ? 1 : 0 }

    /// Gauge ranges, smallest first. `step` is the labelled major tick spacing.
    var scales: [(max: Double, step: Double)] {
        switch self {
        case .kmh: [(60, 10), (120, 20), (200, 40), (300, 50)]
        case .ms:  [(20, 5), (40, 10), (60, 10), (90, 15)]
        case .mph: [(40, 10), (80, 20), (120, 20), (190, 30)]
        }
    }

    func convert(_ metersPerSecond: Double) -> Double { metersPerSecond * factor }
    func format(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond else { return "--" }
        return String(format: "%.\(decimals)f", convert(metersPerSecond))
    }
}

/// Bridges `SpeedometerService` to SwiftUI and keeps per-trip statistics.
@MainActor
@Observable
final class SpeedometerModel {
    private(set) var estimate: SpeedEstimate?
    private(set) var travel: TravelEstimate?
    private(set) var status: SpeedometerService.Status = .stopped
    private(set) var peakSpeed = 0.0      // m/s, measured fixes only
    private(set) var distance = 0.0       // m
    private(set) var movingTime = 0.0     // s, speed > 0.5 m/s

    @ObservationIgnored private let service = SpeedometerService()
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var lastIntegrated: Double?

    var isActive: Bool { status == .running || status == .waitingForPermission }
    var averageSpeed: Double? { movingTime > 1 ? distance / movingTime : nil }

    init(recordingURL: URL? = nil) {
        self.recordingURL = recordingURL
        service.onEstimate = { [weak self] in self?.ingest($0) }
        service.onTravel = { [weak self] in self?.travel = $0 }
        service.onStatus = { [weak self] in self?.statusChanged($0) }
    }

    func start() { service.start(recordingTo: recordingURL) }
    func stop() { service.stop() }
    func toggle() { isActive ? stop() : start() }
    func suspend() { service.suspend() }
    func resume() { service.resume() }

    func resetTrip() {
        peakSpeed = 0; distance = 0; movingTime = 0; lastIntegrated = nil
    }

    private func statusChanged(_ new: SpeedometerService.Status) {
        status = new
        UIApplication.shared.isIdleTimerDisabled = (new == .running)
        if new != .running { lastIntegrated = nil }
    }

    private func ingest(_ new: SpeedEstimate) {
        estimate = new
        guard new.state != .unavailable, let speed = new.speed else { lastIntegrated = nil; return }
        if let last = lastIntegrated {
            let dt = new.timestamp - last
            if dt > 0, dt <= 1 {
                distance += speed * dt
                if speed > 0.5 { movingTime += dt }
            }
        }
        lastIntegrated = new.timestamp
        if new.state == .measured { peakSpeed = max(peakSpeed, speed) }
    }
}
