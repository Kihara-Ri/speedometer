import UIKit
import CoreLocation
import CoreMotion
import Darwin
import os
#if canImport(SpeedCore)
import SpeedCore
#endif

/// No UI. Permissions, sensor start/stop and lifecycle stay on the main actor.
/// Fusion and journaling run in `FusionWorker`, so high-rate sensor callbacks never queue behind UI work.
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
    private let mountAxis: MountAxis?
    private let worker: FusionWorker
    private var generation = 0
    private var journalURL: URL?
    private var journalID: UUID?
    private var batteryObserver: NSObjectProtocol?
    private var requested = false
    private var active = true
    private var running = false

    /// nil means normal handheld operation. Supply an axis ONLY after physically fixing the phone.
    init(mountAxis: MountAxis? = nil) {
        self.mountAxis = mountAxis
        worker = FusionWorker(mountAxis: mountAxis)
        super.init()
        worker.sink = { [weak self] publication in self?.deliver(publication) }
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
        if journalURL != nil { worker.submit { now in
            var event = ReplayEvent(receivedAt: now); event.lifecycle = "recordingStopping"; return event
        } }
        stopSensors()
        status = .stopped
        if journalURL != nil { Task { _ = try? await finishRecording() } }
    }

    private func startRecording(to url: URL) throws {
        guard journalURL == nil else { return }
        let id = UUID()
        let writer = try SensorJournal(url: url) { [weak self] message in
            Task { @MainActor in
                guard let self, self.journalID == id else { return }
                self.stop()
                self.status = .recordingFailed
                self.onRecordingError?(message)
            }
        }
        journalURL = url; journalID = id
        UIDevice.current.isBatteryMonitoringEnabled = true
        worker.setBatteryLevel(UIDevice.current.batteryLevel)
        batteryObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.worker.setBatteryLevel(UIDevice.current.batteryLevel) }
        }
        var hardware = utsname()
        uname(&hardware)
        let hardwareID = withUnsafeBytes(of: &hardware.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let metadata = [
            "schemaVersion": "2", "sessionID": id.uuidString,
            "sensorMode": mountAxis == nil ? "handheld" : "mounted",
            "mountAxis": mountAxis.map { "\($0.x),\($0.y),\($0.z)" } ?? "none",
            "algorithmID": SpeedEstimator.algorithmID,
            "stationaryAlgorithmID": SpeedEstimator.stationaryAlgorithmID,
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
        worker.attach(writer, metadata: metadata)
        // Recording is created before sensors start; begin() owns the single filter reset.
        onRecordingChanged?(true)
    }

    @discardableResult
    func mark(kind: String, note: String) -> RecordingMarker? {
        guard journalURL != nil else { return nil }
        let marker = RecordingMarker(id: worker.nextMarkerID(), kind: kind, note: note)
        worker.submit { now in ReplayEvent(receivedAt: now, marker: marker) }
        return marker
    }

    func respondToArrival(id: String, answer: RailArrivalAnswer) {
        guard running, journalURL != nil, answer != .unanswered else { return }
        worker.submit { now in
            var event = ReplayEvent(receivedAt: now)
            event.railFeedback = RailArrivalFeedback(candidateID: id, answer: answer)
            return event
        }
    }

    private func finishRecording() async throws -> URL? {
        guard let url = journalURL else { return nil }
        journalURL = nil; journalID = nil
        if let batteryObserver { NotificationCenter.default.removeObserver(batteryObserver) }
        batteryObserver = nil
        stopRecordingSensors()
        onRecordingChanged?(false)
        guard let writer = await worker.detach() else { return nil }
        do { try await writer.finish(); onRecordingFinished?(url); return url }
        catch { status = .recordingFailed; onRecordingError?(error.localizedDescription); throw error }
    }

    func suspend() {
        active = false
        guard requested else { return }
        worker.submit { now in var event = ReplayEvent(receivedAt: now); event.lifecycle = "backgroundEntered"; return event }
    }

    func resume() {
        active = true
        if requested {
            worker.submit { now in var event = ReplayEvent(receivedAt: now); event.lifecycle = "foregroundEntered"; return event }
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
        worker.begin(generation: generation)
        location.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable(),
           [.authorized, .notDetermined].contains(CMMotionActivityManager.authorizationStatus()) {
            worker.startActivity(activityManager, generation: generation)
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 20
            worker.startDeviceMotion(motion, generation: generation)
        }
        if journalURL != nil { startRecordingSensors() }
        status = .running
    }

    private func stopSensors() {
        running = false
        generation += 1
        activityManager.stopActivityUpdates()
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        stopRecordingSensors()
        worker.end()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorizeOrBegin() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running else { return }
        let fixes = locations.sorted(by: { $0.timestamp < $1.timestamp }).map { fix in
            LocationFix(wallTime: fix.timestamp.timeIntervalSince1970, speed: fix.speed,
                speedAccuracy: fix.speedAccuracy, horizontalAccuracy: fix.horizontalAccuracy,
                details: LocationDetails(wallTime: fix.timestamp.timeIntervalSince1970,
                    latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, altitude: fix.altitude,
                    verticalAccuracy: fix.verticalAccuracy, course: fix.course, courseAccuracy: fix.courseAccuracy,
                    simulated: fix.sourceInformation?.isSimulatedBySoftware, accessory: fix.sourceInformation?.isProducedByAccessory,
                    rawSpeed: fix.speed, rawSpeedAccuracy: fix.speedAccuracy, rawHorizontalAccuracy: fix.horizontalAccuracy))
        }
        worker.ingest(fixes, generation: generation)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard running else { return }
        worker.recordSensorError("location: \(error.localizedDescription)")
        if (error as? CLError)?.code == .denied {
            stopSensors(); status = .denied
        } else {
            // Temporary locationUnknown does not renew the last observation's age.
            worker.publishEstimate()
        }
    }

    private func startRecordingSensors() {
        guard running else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        motion.deviceMotionUpdateInterval = mountAxis == nil ? 1.0 / 50 : 1.0 / 20
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.gyroUpdateInterval = 1.0 / 50
        motion.magnetometerUpdateInterval = 1.0 / 20
        worker.startRecordingSensors(motion: motion, altimeter: altimeter, generation: generation)
    }

    private func stopRecordingSensors() {
        motion.stopAccelerometerUpdates(); motion.stopGyroUpdates(); motion.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        motion.deviceMotionUpdateInterval = 1.0 / 20
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func deliver(_ publication: FusionWorker.Publication) {
        switch publication {
        case .estimate(let estimate): onEstimate?(estimate)
        case .travel(let travel): onTravel?(travel)
        case .rail(let update): onRail?(update)
        case .arrivalMarker(let marker): onArrivalMarker?(marker)
        }
    }
}

/// One Core Location fix copied into Sendable values before it leaves the main actor.
struct LocationFix: Sendable {
    var wallTime: Double
    var speed: Double
    var speedAccuracy: Double
    var horizontalAccuracy: Double
    var details: LocationDetails
}

/// Owns the fusion pipeline, clocks and journal. Every stored property is touched only on `queue`
/// (Core Motion delivers onto `operationQueue`, whose underlying queue is `queue`), except the
/// lock-protected marker counter. Every event's receipt time is read on `queue`, so the journal and
/// the pipeline see one non-decreasing clock across all sensors.
final class FusionWorker: @unchecked Sendable {
    enum Publication: Sendable {
        case estimate(SpeedEstimate), travel(TravelEstimate), rail(RailArrivalUpdate), arrivalMarker(RecordingMarker)
    }
    /// Called on the main actor. Set once, before any sensor starts.
    var sink: (@MainActor @Sendable (Publication) -> Void)?

    private let queue = DispatchQueue(label: "speedometer.fusion", qos: .userInitiated)
    private let operationQueue = OperationQueue()
    private let mountAxis: MountAxis?
    private var pipeline: FusionPipeline
    private var journal: SensorJournal?
    private var clock = LocationClock()
    private var mountMonitor = MountMonitor()
    private var activitySource: ActivitySource = .waiting
    private var generation = 0
    private var batteryLevel: Float = -1
    private var timer: DispatchSourceTimer?
    private var publishedRail: (current: RailArrivalCandidate?, isRailLike: Bool)?
    private var publishedTravel: TravelEstimate?
    private let markerCount = OSAllocatedUnfairLock(initialState: 0)

    init(mountAxis: MountAxis?) {
        self.mountAxis = mountAxis
        pipeline = FusionPipeline(mode: mountAxis == nil ? .handheld : .mounted)
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Main-actor entry points. Each hops onto the queue and keeps submission order.

    func submit(_ make: @escaping @Sendable (Double) -> ReplayEvent) {
        queue.async { [self] in record(make(now)) }
    }

    func nextMarkerID() -> String {
        let value = markerCount.withLock { count -> Int in count += 1; return count }
        return String(format: "M%03d", value)
    }

    func setBatteryLevel(_ level: Float) { queue.async { [self] in batteryLevel = level } }

    func attach(_ writer: SensorJournal, metadata: [String: String]) {
        markerCount.withLock { $0 = 0 }
        queue.async { [self] in
            journal = writer
            var header = ReplayEvent(receivedAt: now)
            header.metadata = metadata
            record(header)
        }
    }

    /// Records the end of the session and hands back the writer; earlier appends are already queued to it.
    func detach() async -> SensorJournal? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var event = ReplayEvent(receivedAt: now)
                event.lifecycle = "recordingEnded"
                record(event)
                let writer = journal
                journal = nil
                continuation.resume(returning: writer)
            }
        }
    }

    func begin(generation expected: Int) {
        queue.async { [self] in
            generation = expected
            clock = LocationClock(); mountMonitor = MountMonitor()
            record(ReplayEvent(receivedAt: now, reset: true))
            refreshActivitySource()
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(20))
            heartbeat.setEventHandler { [weak self] in self?.tick() }
            heartbeat.resume()
            timer = heartbeat
        }
    }

    func end() {
        queue.async { [self] in
            generation = 0
            timer?.cancel(); timer = nil
            record(ReplayEvent(receivedAt: now, reset: true))
            setActivitySource(.stopped)
            publish(.estimate(pipeline.estimate(at: now)))
        }
    }

    func ingest(_ fixes: [LocationFix], generation expected: Int) {
        queue.async { [self] in
            guard generation == expected else { return }
            for fix in fixes { ingest(fix) }
        }
    }

    func recordSensorError(_ message: String) {
        queue.async { [self] in
            var event = ReplayEvent(receivedAt: now)
            event.sensorError = message
            record(event)
        }
    }

    func publishEstimate() { queue.async { [self] in publish(.estimate(pipeline.estimate(at: now))) } }

    // MARK: Sensor subscriptions. Handlers are formed here, outside the main actor, and run on the queue.

    func startActivity(_ manager: CMMotionActivityManager, generation expected: Int) {
        manager.startActivityUpdates(to: operationQueue) { [weak self] activity in
            guard let self, self.generation == expected else { return }
            self.handle(activity)
        }
    }

    func startDeviceMotion(_ manager: CMMotionManager, generation expected: Int) {
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: operationQueue) { [weak self] data, error in
            guard let self, self.generation == expected else { return }
            if let error { self.recordError("deviceMotion", error); return }
            guard let data else { return }
            self.handle(data)
        }
    }

    func startRecordingSensors(motion: CMMotionManager, altimeter: CMAltimeter, generation expected: Int) {
        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: operationQueue) { [weak self] data, error in
                guard let self, self.generation == expected, self.journal != nil else { return }
                if let error { self.recordError("accelerometer", error); return }
                guard let data else { return }
                let a = data.acceleration
                var event = ReplayEvent(receivedAt: self.now)
                event.accelerometer = VectorSample(timestamp: data.timestamp, values: [a.x, a.y, a.z])
                self.record(event)
            }
        }
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: operationQueue) { [weak self] data, error in
                guard let self, self.generation == expected, self.journal != nil else { return }
                if let error { self.recordError("gyroscope", error); return }
                guard let data else { return }
                let r = data.rotationRate
                var event = ReplayEvent(receivedAt: self.now)
                event.gyroscope = VectorSample(timestamp: data.timestamp, values: [r.x, r.y, r.z])
                self.record(event)
            }
        }
        if motion.isMagnetometerAvailable {
            motion.startMagnetometerUpdates(to: operationQueue) { [weak self] data, error in
                guard let self, self.generation == expected, self.journal != nil else { return }
                if let error { self.recordError("magnetometer", error); return }
                guard let data else { return }
                let m = data.magneticField
                var event = ReplayEvent(receivedAt: self.now)
                event.magnetometer = VectorSample(timestamp: data.timestamp, values: [m.x, m.y, m.z])
                self.record(event)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: operationQueue) { [weak self] data, error in
                guard let self, self.generation == expected, self.journal != nil else { return }
                if let error { self.recordError("altimeter", error); return }
                guard let data else { return }
                var event = ReplayEvent(receivedAt: self.now)
                event.relativeAltitude = data.relativeAltitude.doubleValue
                event.pressure = data.pressure.doubleValue
                event.altitudeTimestamp = data.timestamp
                self.record(event)
            }
        }
    }

    // MARK: Queue-confined processing.

    private func tick() {
        guard generation != 0 else { return }
        refreshActivitySource()
        let output = record(ReplayEvent(receivedAt: now))
        publish(.estimate(output.estimate))
        var travel = output.travel
        if let previous = publishedTravel { travel.timestamp = previous.timestamp }
        if travel != publishedTravel {
            publishedTravel = output.travel
            publish(.travel(output.travel))
        }
    }

    private func ingest(_ fix: LocationFix) {
        let receivedAt = now
        guard let timestamp = clock.convert(fixWallTime: fix.wallTime, wallNow: Date().timeIntervalSince1970,
                                            monotonicNow: receivedAt) else {
            var event = ReplayEvent(receivedAt: receivedAt, resetSpeedOnly: true)
            event.locationDetails = fix.details
            event.sensorError = "locationClock: wall-clock discontinuity"
            record(event)
            return
        }
        let sample = SpeedObservation(timestamp: timestamp, speed: fix.speed,
                                      speedAccuracy: fix.speedAccuracy, horizontalAccuracy: fix.horizontalAccuracy)
        var event = ReplayEvent(receivedAt: receivedAt, speed: sample)
        event.locationDetails = fix.details
        let output = record(event)
        publish(.estimate(output.estimate))
    }

    private func handle(_ data: CMDeviceMotion) {
        let a = data.userAcceleration, r = data.rotationRate, g = data.gravity, q = data.attitude.quaternion
        let raw = RawMotion(acceleration: [a.x, a.y, a.z], gravity: [g.x, g.y, g.z],
                            rotationRate: [r.x, r.y, r.z], quaternion: [q.x, q.y, q.z, q.w], timestamp: data.timestamp)
        var projected: MotionObservation?
        if let mountAxis {
            projected = MotionObservation(timestamp: data.timestamp,
                acceleration: mountAxis.acceleration(x: a.x, y: a.y, z: a.z),
                rotationRate: mountMonitor.accepts(x: q.x, y: q.y, z: q.z, w: q.w) ? hypot(hypot(r.x, r.y), r.z) : 1)
        }
        record(ReplayEvent(receivedAt: now, motion: projected, rawMotion: raw))
    }

    private func handle(_ activity: CMMotionActivity?) {
        refreshActivitySource()
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
        record(ReplayEvent(receivedAt: observation.timestamp, activity: observation))
    }

    private func refreshActivitySource() {
        guard CMMotionActivityManager.isActivityAvailable() else { setActivitySource(.unavailable); return }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: setActivitySource(.available)
        case .denied: setActivitySource(.denied)
        case .restricted: setActivitySource(.restricted)
        case .notDetermined: setActivitySource(.waiting)
        @unknown default: setActivitySource(.unavailable)
        }
    }

    private func setActivitySource(_ source: ActivitySource) {
        guard source != activitySource else { return }
        activitySource = source
        record(ReplayEvent(receivedAt: now, activitySource: source))
    }

    private func recordError(_ sensor: String, _ error: any Error) {
        var event = ReplayEvent(receivedAt: now)
        event.sensorError = "\(sensor): \(error.localizedDescription)"
        record(event)
    }

    /// Every input goes through the shared pipeline even when disk recording is off,
    /// in exactly the order replay will see it.
    @discardableResult
    private func record(_ input: ReplayEvent) -> ReplayOutput {
        dispatchPrecondition(condition: .onQueue(queue))
        var event = input
        if event.reset == true { activitySource = .waiting }
        let output = pipeline.processForRecording(&event)
        let rail = output.rail
        if publishedRail?.current != rail.current || publishedRail?.isRailLike != rail.isRailLike {
            publishedRail = (rail.current, rail.isRailLike)
            publish(.rail(rail))
        }
        guard let journal else { return output }
        if let resolution = rail.resolved, resolution.answer == .confirmed {
            let marker = RecordingMarker(id: nextMarkerID(), kind: "arrival", note: "确认到站",
                                         timestamp: resolution.stoppedAt, candidateID: resolution.candidateID)
            event.marker = marker
            publish(.arrivalMarker(marker))
        }
        event.wallTime = Date().timeIntervalSince1970
        if !FusionPipeline.isSupplemental(event) {
            event.batteryLevel = batteryLevel
            event.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        }
        journal.append(event)
        return output
    }

    private func publish(_ publication: Publication) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { sink?(publication) }
        }
    }
}
