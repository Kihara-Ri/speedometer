import UIKit
import CoreLocation
import CoreMotion
#if canImport(SpeedCore)
import SpeedCore
#endif

/// No UI. All delivery and sensor ownership are isolated to the main actor.
@MainActor
final class SpeedometerService: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Status: String { case stopped, waitingForPermission, running, denied, preciseLocationRequired, suspended, recordingFailed }
    var onEstimate: ((SpeedEstimate) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onTravel: ((TravelEstimate) -> Void)?
    private(set) var status: Status = .stopped { didSet { onStatus?(status) } }
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private var activitySource: ActivitySource = .waiting
    private var travel = TravelModeRecognizer()
    private var generation = 0
    private let mountAxis: MountAxis?
    private var engine: SpeedEstimator
    private var clock = LocationClock()
    private var mountMonitor = MountMonitor()
    private var timer: Timer?
    private var journal: FileHandle?
    private var requested = false
    private var active = true
    private var running = false

    /// nil means normal handheld operation. Supply an axis ONLY after physically fixing the phone.
    init(mountAxis: MountAxis? = nil) {
        self.mountAxis = mountAxis
        engine = SpeedEstimator(mode: mountAxis == nil ? .handheld : .mounted)
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        // Train journeys must not be constrained to the road network.
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
    }

    func start(recordingTo url: URL? = nil) {
        guard !requested else { return }
        requested = true
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                journal = try FileHandle(forWritingTo: url)
                try journal?.seekToEnd()
            } catch { status = .recordingFailed; requested = false; return }
        }
        authorizeOrBegin()
    }

    func stop() {
        requested = false
        stopSensors()
        try? journal?.close(); journal = nil
        status = .stopped
    }

    func suspend() {
        active = false
        guard requested else { return }
        stopSensors()
        status = .suspended
    }

    func resume() {
        active = true
        if requested { authorizeOrBegin() }
    }

    private func authorizeOrBegin() {
        guard requested, active else { return }
        switch location.authorizationStatus {
        case .notDetermined:
            status = .waitingForPermission
            location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard location.accuracyAuthorization == .fullAccuracy else {
                stopSensors(); status = .preciseLocationRequired; return
            }
            begin()
        case .denied, .restricted:
            stopSensors(); status = .denied
        @unknown default:
            stopSensors(); status = .denied
        }
    }

    private func begin() {
        guard !running else { return }
        running = true
        generation += 1
        let expectedGeneration = generation
        engine.reset(); clock = LocationClock(); mountMonitor = MountMonitor()
        record(ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime, reset: true))
        location.startUpdatingLocation()
        refreshActivitySource(at: ProcessInfo.processInfo.systemUptime)
        if activitySource == .available || activitySource == .waiting {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == expectedGeneration else { return }
                    self.handleActivity(activity)
                }
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 20
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.running, let data, error == nil else { return }
                    self.handleMotion(data)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.refreshActivitySource(at: now)
                self.record(ReplayEvent(receivedAt: now))
                self.onEstimate?(self.engine.estimate(at: now))
            }
        }
        status = .running
    }

    private func stopSensors() {
        running = false
        generation += 1
        activityManager.stopActivityUpdates()
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        timer?.invalidate(); timer = nil
        engine.reset()
        let now = ProcessInfo.processInfo.systemUptime
        record(ReplayEvent(receivedAt: now, reset: true))
        setActivitySource(.stopped, at: now)
        onEstimate?(engine.estimate(at: now))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorizeOrBegin() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running else { return }
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let now = ProcessInfo.processInfo.systemUptime
            guard let timestamp = clock.convert(fixWallTime: fix.timestamp.timeIntervalSince1970,
                                                 wallNow: Date().timeIntervalSince1970, monotonicNow: now) else {
                engine.reset(); record(ReplayEvent(receivedAt: now, resetSpeedOnly: true)); continue
            }
            let sample = SpeedObservation(timestamp: timestamp, speed: fix.speed,
                                          speedAccuracy: fix.speedAccuracy, horizontalAccuracy: fix.horizontalAccuracy)
            let result = engine.ingest(sample, receivedAt: now)
            if result == .accepted { _ = travel.ingestSpeed(sample, receivedAt: now) }
            record(ReplayEvent(receivedAt: now, speed: sample))
            onEstimate?(engine.estimate(at: now))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard running else { return }
        if (error as? CLError)?.code == .denied {
            stopSensors(); status = .denied
        } else {
            // Temporary locationUnknown does not renew the last observation's age.
            onEstimate?(engine.estimate(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func handleMotion(_ data: CMDeviceMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        let a = data.userAcceleration, r = data.rotationRate, g = data.gravity, q = data.attitude.quaternion
        let raw = RawMotion(acceleration: [a.x,a.y,a.z], gravity: [g.x,g.y,g.z],
                            rotationRate: [r.x,r.y,r.z], quaternion: [q.x,q.y,q.z,q.w])
        var projected: MotionObservation?
        if let mountAxis {
            projected = MotionObservation(timestamp: data.timestamp,
                acceleration: mountAxis.acceleration(x: a.x, y: a.y, z: a.z),
                rotationRate: mountMonitor.accepts(x: q.x, y: q.y, z: q.z, w: q.w) ? hypot(hypot(r.x, r.y), r.z) : 1)
            _ = engine.ingest(projected!, receivedAt: now)
        }
        record(ReplayEvent(receivedAt: now, motion: projected, rawMotion: raw))
    }

    private func refreshActivitySource(at now: Double) {
        guard CMMotionActivityManager.isActivityAvailable() else {
            setActivitySource(.unavailable, at: now); return
        }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: setActivitySource(.available, at: now)
        case .denied: setActivitySource(.denied, at: now)
        case .restricted: setActivitySource(.restricted, at: now)
        case .notDetermined: setActivitySource(.waiting, at: now)
        @unknown default: setActivitySource(.unavailable, at: now)
        }
    }

    private func setActivitySource(_ source: ActivitySource, at now: Double) {
        guard source != activitySource else { return }
        activitySource = source
        record(ReplayEvent(receivedAt: now, activitySource: source))
    }

    private func handleActivity(_ activity: CMMotionActivity?) {
        let now = ProcessInfo.processInfo.systemUptime
        refreshActivitySource(at: now)
        guard activitySource == .available else { return }
        let confidence: ActivityConfidence
        switch activity?.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        default: confidence = .low
        }
        let observation = ActivityObservation(timestamp: now, confidence: confidence,
            automotive: activity?.automotive ?? false, walking: activity?.walking ?? false,
            running: activity?.running ?? false, cycling: activity?.cycling ?? false,
            stationary: activity?.stationary ?? false, unknown: activity?.unknown ?? true,
            startedAtWallTime: activity?.startDate.timeIntervalSince1970)
        record(ReplayEvent(receivedAt: now, activity: observation))
    }

    private func record(_ event: ReplayEvent) {
        // Process every input even when disk recording is disabled. Replay uses the same event order.
        if event.reset == true { travel.reset(); activitySource = .waiting }
        if let source = event.activitySource { travel.setSource(source, at: event.receivedAt) }
        if let activity = event.activity { _ = travel.ingest(activity, receivedAt: event.receivedAt) }
        onTravel?(travel.advance(to: event.receivedAt))
        guard let journal else { return }
        do {
            let encoder = JSONEncoder()
            // Preserve invalid sensor values so the replay exercises the same rejection path.
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            var line = try encoder.encode(event)
            line.append(10)
            try journal.write(contentsOf: line)
        } catch {
            try? journal.close(); self.journal = nil
            status = .recordingFailed
        }
    }
}
