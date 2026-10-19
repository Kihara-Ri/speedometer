import UIKit
import CoreLocation
import CoreMotion
import Darwin
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
    var onRail: ((RailArrivalUpdate) -> Void)?
    var onArrivalMarker: ((RecordingMarker) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onRecordingFinished: ((URL) -> Void)?
    private(set) var status: Status = .stopped { didSet { onStatus?(status) } }
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let altimeter = CMAltimeter()
    private var activitySource: ActivitySource = .waiting
    private var travel = TravelModeRecognizer()
    private var rail = RailArrivalRecognizer()
    private var generation = 0
    private let mountAxis: MountAxis?
    private var engine: SpeedEstimator
    private var clock = LocationClock()
    private var mountMonitor = MountMonitor()
    private var timer: Timer?
    private var journal: SensorJournal?
    private var journalURL: URL?
    private var journalID: UUID?
    private var markerCount = 0
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
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
    }

    func start(recordingTo url: URL) {
        guard !requested else { return }
        requested = true
        do { try startRecording(to: url) }
        catch {
            requested = false
            status = .recordingFailed
            onRecordingError?(error.localizedDescription)
            return
        }
        authorizeOrBegin()
    }

    func stop() {
        requested = false
        if journal != nil {
            var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
            event.lifecycle = "recordingStopping"
            record(event)
        }
        stopSensors()
        status = .stopped
        if journal != nil { Task { _ = try? await finishRecording() } }
    }

    private func startRecording(to url: URL) throws {
        guard journal == nil else { return }
        let id = UUID()
        let writer = try SensorJournal(url: url) { [weak self] message in
            Task { @MainActor in
                guard let self, self.journalID == id else { return }
                self.stop()
                self.status = .recordingFailed
                self.onRecordingError?(message)
            }
        }
        journal = writer; journalURL = url; journalID = id; markerCount = 0
        UIDevice.current.isBatteryMonitoringEnabled = true
        var hardware = utsname()
        uname(&hardware)
        let hardwareID = withUnsafeBytes(of: &hardware.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var header = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
        header.metadata = [
            "schemaVersion": "2", "sessionID": id.uuidString,
            "sensorMode": mountAxis == nil ? "handheld" : "mounted",
            "mountAxis": mountAxis.map { "\($0.x),\($0.y),\($0.z)" } ?? "none",
            "algorithmID": "kalman-v1-2026-10-17",
            "stationaryAlgorithmID": "stationary-v2-2026-10-19",
            "railAlgorithmID": RailArrivalRecognizer.algorithmID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "systemVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
            "deviceHardware": hardwareID,
            "motionReferenceFrame": "xArbitraryZVertical", "requestedMotionHz": mountAxis == nil ? "50" : "20",
            "requestedAccelerometerHz": "50", "requestedGyroHz": "50", "requestedMagnetometerHz": "20",
            "accelerometerAvailable": String(motion.isAccelerometerAvailable),
            "gyroAvailable": String(motion.isGyroAvailable),
            "magnetometerAvailable": String(motion.isMagnetometerAvailable),
            "deviceMotionAvailable": String(motion.isDeviceMotionAvailable),
            "relativeAltitudeAvailable": String(CMAltimeter.isRelativeAltitudeAvailable()),
            "locationAuthorization": String(location.authorizationStatus.rawValue),
            "accuracyAuthorization": String(location.accuracyAuthorization.rawValue),
            "units": "time=s; speed=m/s; projectedAcceleration=m/s²; acceleration/gravity=g; gyro=rad/s; magnetometer=µT; pressure=kPa; distance=m",
            "backgroundPolicy": "continuous-location-and-motion; foreground-start; OS-termination-not-guaranteed"
        ]
        record(header)
        // Recording is created before sensors start; begin() owns the single filter reset.
        onRecordingChanged?(true)
    }

    @discardableResult
    func mark(kind: String, note: String) -> RecordingMarker? {
        guard journal != nil else { return nil }
        markerCount += 1
        let marker = RecordingMarker(id: String(format: "M%03d", markerCount), kind: kind, note: note)
        record(ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime, marker: marker))
        return marker
    }

    func respondToArrival(id: String, answer: RailArrivalAnswer) {
        guard running, journal != nil, answer != .unanswered else { return }
        var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
        event.railFeedback = RailArrivalFeedback(candidateID: id, answer: answer)
        record(event)
    }

    private func finishRecording() async throws -> URL? {
        guard let writer = journal, let url = journalURL else { return nil }
        var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
        event.lifecycle = "recordingEnded"; record(event)
        journal = nil; journalURL = nil; journalID = nil
        stopRecordingSensors()
        onRecordingChanged?(false)
        do { try await writer.finish(); onRecordingFinished?(url); return url }
        catch { status = .recordingFailed; onRecordingError?(error.localizedDescription); throw error }
    }

    func suspend() {
        active = false
        guard requested else { return }
        var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
        event.lifecycle = "backgroundEntered"; record(event)
    }

    func resume() {
        active = true
        if requested {
            var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
            event.lifecycle = "foregroundEntered"; record(event)
            authorizeOrBegin()
        }
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
                    guard let self, self.running, self.generation == expectedGeneration else { return }
                    if let error { self.recordSensorError("deviceMotion", error); return }
                    guard let data else { return }
                    self.handleMotion(data)
                }
            }
        }
        if journal != nil { startRecordingSensors() }
        let heartbeat = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.refreshActivitySource(at: now)
                self.record(ReplayEvent(receivedAt: now))
                self.onEstimate?(self.engine.estimate(at: now))
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
        status = .running
    }

    private func stopSensors() {
        running = false
        generation += 1
        activityManager.stopActivityUpdates()
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        stopRecordingSensors()
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
            let details = LocationDetails(wallTime: fix.timestamp.timeIntervalSince1970,
                latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, altitude: fix.altitude,
                verticalAccuracy: fix.verticalAccuracy, course: fix.course, courseAccuracy: fix.courseAccuracy,
                simulated: fix.sourceInformation?.isSimulatedBySoftware, accessory: fix.sourceInformation?.isProducedByAccessory,
                rawSpeed: fix.speed, rawSpeedAccuracy: fix.speedAccuracy, rawHorizontalAccuracy: fix.horizontalAccuracy)
            guard let timestamp = clock.convert(fixWallTime: fix.timestamp.timeIntervalSince1970,
                                                 wallNow: Date().timeIntervalSince1970, monotonicNow: now) else {
                engine.reset()
                var event = ReplayEvent(receivedAt: now, resetSpeedOnly: true)
                event.locationDetails = details
                event.sensorError = "locationClock: wall-clock discontinuity"
                record(event); continue
            }
            let sample = SpeedObservation(timestamp: timestamp, speed: fix.speed,
                                          speedAccuracy: fix.speedAccuracy, horizontalAccuracy: fix.horizontalAccuracy)
            let result = engine.ingest(sample, receivedAt: now)
            if result == .accepted { _ = travel.ingestSpeed(sample, receivedAt: now) }
            var event = ReplayEvent(receivedAt: now, speed: sample)
            event.locationDetails = details
            record(event, acceptedSpeed: result == .accepted)
            onEstimate?(engine.estimate(at: now))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard running else { return }
        recordSensorError("location", error)
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
                            rotationRate: [r.x,r.y,r.z], quaternion: [q.x,q.y,q.z,q.w], timestamp: data.timestamp)
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

    private func record(_ input: ReplayEvent, acceptedSpeed: Bool = false) {
        var event = input
        engine.observeStationaryEvidence(event)
        // Process every input even when disk recording is disabled. Replay uses the same event order.
        if event.reset == true { travel.reset(); activitySource = .waiting }
        if let source = event.activitySource { travel.setSource(source, at: event.receivedAt) }
        if let activity = event.activity { _ = travel.ingest(activity, receivedAt: event.receivedAt) }
        onTravel?(travel.advance(to: event.receivedAt))
        let update = rail.consume(event, acceptedSpeed: acceptedSpeed)
        onRail?(update)
        guard let journal else { return }
        event.railCandidate = update.created
        event.railResolution = update.resolved
        if let resolution = update.resolved, resolution.answer == .confirmed {
            markerCount += 1
            let marker = RecordingMarker(id: String(format: "M%03d", markerCount), kind: "arrival",
                note: "确认到站", timestamp: resolution.stoppedAt, candidateID: resolution.candidateID)
            event.marker = marker
            onArrivalMarker?(marker)
        }
        event.wallTime = Date().timeIntervalSince1970
        let supplemental = event.accelerometer != nil || event.gyroscope != nil || event.magnetometer != nil ||
            event.pressure != nil || (event.rawMotion != nil && event.motion == nil)
        if !supplemental {
            event.recordedEstimate = engine.estimate(at: event.receivedAt)
            event.diagnostics = engine.diagnostics(at: event.receivedAt)
            event.batteryLevel = UIDevice.current.batteryLevel
            event.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        }
        journal.append(event)
    }

    private func recordSensorError(_ sensor: String, _ error: any Error) {
        var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
        event.sensorError = "\(sensor): \(error.localizedDescription)"; record(event)
    }

    private func startRecordingSensors() {
        guard running else { return }
        let expected = generation
        let expectedRecording = journalID
        UIDevice.current.isBatteryMonitoringEnabled = true
        motion.deviceMotionUpdateInterval = mountAxis == nil ? 1.0 / 50 : 1.0 / 20
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.gyroUpdateInterval = 1.0 / 50
        motion.magnetometerUpdateInterval = 1.0 / 20
        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == expected, self.journalID == expectedRecording, self.journal != nil else { return }
                    if let error { self.recordSensorError("accelerometer", error); return }
                    guard let data else { return }
                    let a = data.acceleration
                    var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
                    event.accelerometer = VectorSample(timestamp: data.timestamp, values: [a.x,a.y,a.z])
                    self.record(event)
                }
            }
        }
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == expected, self.journalID == expectedRecording, self.journal != nil else { return }
                    if let error { self.recordSensorError("gyroscope", error); return }
                    guard let data else { return }
                    let r = data.rotationRate
                    var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
                    event.gyroscope = VectorSample(timestamp: data.timestamp, values: [r.x,r.y,r.z])
                    self.record(event)
                }
            }
        }
        if motion.isMagnetometerAvailable {
            motion.startMagnetometerUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == expected, self.journalID == expectedRecording, self.journal != nil else { return }
                    if let error { self.recordSensorError("magnetometer", error); return }
                    guard let data else { return }
                    let m = data.magneticField
                    var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
                    event.magnetometer = VectorSample(timestamp: data.timestamp, values: [m.x,m.y,m.z])
                    self.record(event)
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == expected, self.journalID == expectedRecording, self.journal != nil else { return }
                    if let error { self.recordSensorError("altimeter", error); return }
                    guard let data else { return }
                    var event = ReplayEvent(receivedAt: ProcessInfo.processInfo.systemUptime)
                    event.relativeAltitude = data.relativeAltitude.doubleValue
                    event.pressure = data.pressure.doubleValue
                    event.altitudeTimestamp = data.timestamp
                    self.record(event)
                }
            }
        }
    }

    private func stopRecordingSensors() {
        motion.stopAccelerometerUpdates(); motion.stopGyroUpdates(); motion.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        motion.deviceMotionUpdateInterval = 1.0 / 20
        UIDevice.current.isBatteryMonitoringEnabled = false
    }
}
