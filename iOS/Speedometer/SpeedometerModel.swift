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
    private(set) var rail: RailArrivalUpdate?
    private(set) var status: SpeedometerService.Status = .stopped
    private(set) var peakSpeed = 0.0      // m/s, measured fixes only
    private(set) var distance = 0.0       // m
    private(set) var movingTime = 0.0     // s, speed > 0.5 m/s
    private(set) var isRecording = false
    private(set) var isFinalizingRecording = false
    private(set) var recordingError: String?
    private(set) var recordings: [RecordingEntry] = []
    private(set) var deletedRecordings: [RecordingEntry] = []
    private(set) var markers: [RecordingMarker] = []
    private(set) var lastExport: URL?
    private(set) var recordingStartedUptime: Double?
    /// Diagnostic only: also journal raw accelerometer/gyro/magnetometer. Applies from the next start.
    var recordRawIMU = UserDefaults.standard.bool(forKey: "recordRawIMU") {
        didSet { UserDefaults.standard.set(recordRawIMU, forKey: "recordRawIMU") }
    }
    private var recordingEndedUptime: Double?

    @ObservationIgnored private let service = SpeedometerService()
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var integral = DistanceAccumulator()

    var isActive: Bool { status == .running || status == .waitingForPermission }
    var recordingDuration: TimeInterval {
        guard let start = recordingStartedUptime else { return 0 }
        return max(0, (recordingEndedUptime ?? ProcessInfo.processInfo.systemUptime) - start)
    }
    var averageSpeed: Double? { movingTime > 1 ? distance / movingTime : nil }
    var recordingStore: RecordingStore {
        RecordingStore(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    init(recordingURL: URL? = nil) {
        self.recordingURL = recordingURL
        service.onEstimate = { [weak self] in self?.ingest($0) }
        service.onTravel = { [weak self] in self?.travel = $0 }
        service.onRail = { [weak self] update in
            guard let self else { return }
            // Raw sensor callbacks run at 50 Hz; redraw only when visible rail state changes.
            if self.rail?.current != update.current || self.rail?.isRailLike != update.isRailLike {
                self.rail = update
            }
        }
        service.onArrivalMarker = { [weak self] in self?.markers.append($0) }
        service.onStatus = { [weak self] in self?.statusChanged($0) }
        service.onRecordingChanged = { [weak self] active in
            guard let self else { return }
            if !active, self.isRecording { self.isFinalizingRecording = true }
            if active { self.recordingStartedUptime = ProcessInfo.processInfo.systemUptime; self.recordingEndedUptime = nil }
            else { self.recordingEndedUptime = ProcessInfo.processInfo.systemUptime }
            self.isRecording = active
        }
        service.onRecordingError = { [weak self] message in
            self?.recordingError = message
            self?.isFinalizingRecording = false
            self?.recordingURL = nil
            self?.refreshRecordings()
        }
        service.onRecordingFinished = { [weak self] url in
            guard let self else { return }
            self.recordingURL = nil; self.isFinalizingRecording = false
            self.lastExport = url; self.refreshRecordings()
        }
    }

    func start() {
        guard !isActive, !isRecording, !isFinalizingRecording else { return }
        recordingError = nil; markers = []; lastExport = nil
        let url = recordingURL ?? recordingStore.directory
            .appendingPathComponent("session-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jsonl")
        recordingURL = url
        resetTrip()
        service.start(recordingTo: url, rawIMU: recordRawIMU)
        if isRecording { addMarker(kind: "recordingStarted", note: "开始测速") }
    }
    func stop() {
        if isRecording { isFinalizingRecording = true }
        service.stop()
    }
    func toggle() { isActive || isRecording ? stop() : start() }
    func suspend() { service.suspend() }
    func resume() { service.resume() }

    func addMarker(kind: String, note: String) {
        if let marker = service.mark(kind: kind, note: note) { markers.append(marker) }
    }

    func respondToArrival(id: String, answer: RailArrivalAnswer) {
        service.respondToArrival(id: id, answer: answer)
    }

    func refreshRecordings() {
        do {
            try recordingStore.purgeTrash()
            recordings = try recordingStore.entries().filter { $0.url != recordingURL }
            deletedRecordings = try recordingStore.entries(deleted: true)
        } catch { recordingError = error.localizedDescription }
    }

    func saveRecordingInfo(_ info: RecordingInfo, for url: URL) throws {
        try recordingStore.save(info, for: url); refreshRecordings()
    }

    func trashRecording(_ entry: RecordingEntry) throws {
        guard entry.url != recordingURL else { return }
        try recordingStore.moveToTrash(entry.url); refreshRecordings()
    }

    func restoreRecording(_ entry: RecordingEntry) throws {
        try recordingStore.restore(entry.url); refreshRecordings()
    }

    private func resetTrip() {
        peakSpeed = 0; distance = 0; movingTime = 0; integral = DistanceAccumulator()
    }

    private func statusChanged(_ new: SpeedometerService.Status) {
        status = new
        UIApplication.shared.isIdleTimerDisabled = (new == .running)
        if new != .running { integral.breakContinuity() }
    }

    private func ingest(_ new: SpeedEstimate) {
        estimate = new
        integral.ingest(new)
        distance = integral.meters; movingTime = integral.movingSeconds
        guard new.state != .unavailable, let speed = new.speed else { return }
        if new.state == .measured { peakSpeed = max(peakSpeed, speed) }
    }
}
