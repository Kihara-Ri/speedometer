import Foundation

public struct SensorStatistics: Sendable {
    public private(set) var count = 0
    public private(set) var firstTime: Double?
    public private(set) var lastTime: Double?
    public private(set) var largestInterval = 0.0
    private var delaySum = 0.0
    private var delays = 0
    public var averageHz: Double? {
        guard count > 1, let firstTime, let lastTime, lastTime > firstTime else { return nil }
        return Double(count - 1) / (lastTime - firstTime)
    }
    public var averageDelay: Double? { delays > 0 ? delaySum / Double(delays) : nil }
    mutating func ingest(time: Double, receivedAt: Double) {
        count += 1
        guard time.isFinite else { return }
        if firstTime == nil { firstTime = time }
        if let lastTime, time > lastTime { largestInterval = max(largestInterval, time - lastTime) }
        lastTime = max(lastTime ?? time, time)
        if receivedAt >= time { delaySum += receivedAt - time; delays += 1 }
    }
}

public struct SessionSample: Identifiable, Sendable {
    public var id: Int
    public var timestamp: Double
    public var speed: Double?
    public var uncertainty: Double?
    public var state: EstimateState
    public var source: EstimateSource
    public var observationAge: Double?
    public var cumulativeMeters: Double
    public var run: Int
    public var diagnostics: FilterDiagnostics?
    public var motion: RawMotion?
    public var accelerometer: VectorSample?
    public var gyroscope: VectorSample?
    public var magnetometer: VectorSample?
    public var location: LocationDetails?
    public var rawSpeed: SpeedObservation?
    public var pressure: Double?
    public var relativeAltitude: Double?
    public var batteryLevel: Float?
    public var thermalState: Int?
}

public struct SessionMarker: Identifiable, Sendable {
    public var marker: RecordingMarker
    public var timestamp: Double
    public var id: String { marker.id }
    public var title: String { marker.note.isEmpty ? marker.id : marker.note }
}

public struct DistanceSummary: Sendable {
    public var meters: Double
    public var duration: Double
    public var coveredSeconds: Double
    public var longestGap: Double
    public var coverage: Double { duration > 0 ? min(1, coveredSeconds / duration) : 0 }
    public var isComplete: Bool { duration > 0 && duration - coveredSeconds <= 1e-6 }
    public var averageSpeed: Double? { isComplete ? meters / duration : nil }
}

public struct StationSegment: Identifiable, Sendable {
    public var start: SessionMarker
    public var end: SessionMarker
    public var distance: DistanceSummary
    public var id: String { start.id + ":" + end.id }
    public var title: String { start.title + " → " + end.title }
}

public struct SessionReport: Sendable {
    public private(set) var samples: [SessionSample] = []
    public private(set) var markers: [SessionMarker] = []
    public private(set) var railCandidates: [RailArrivalCandidate] = []
    public private(set) var railResolutions: [RailArrivalResolution] = []
    public private(set) var metadata: [String: String] = [:]
    public private(set) var sensorStats: [String: SensorStatistics] = [:]
    public private(set) var eventCount = 0
    public private(set) var malformedLines = 0
    public private(set) var sensorErrors: [String] = []
    public private(set) var endedNormally = false
    public private(set) var startTime = 0.0
    public private(set) var endTime = 0.0
    public private(set) var wallStart: Double?
    public private(set) var wallEnd: Double?
    public var duration: Double { max(0, endTime - startTime) }
    public var peakSpeed: Double? { samples.compactMap(\.speed).max() }
    public var distance: DistanceSummary { distance(from: startTime, to: endTime) }
    public var stationSegments: [StationSegment] {
        var start: SessionMarker?
        var result: [StationSegment] = []
        for marker in markers {
            if marker.marker.kind == "departure" { start = marker }
            if marker.marker.kind == "arrival", let departure = start, marker.timestamp > departure.timestamp {
                result.append(StationSegment(start: departure, end: marker,
                    distance: distance(from: departure.timestamp, to: marker.timestamp)))
                start = nil
            }
        }
        return result
    }

    public func distance(from start: Double, to end: Double) -> DistanceSummary {
        guard start.isFinite, end.isFinite, end > start else {
            return DistanceSummary(meters: 0, duration: 0, coveredSeconds: 0, longestGap: 0)
        }
        var meters = 0.0, covered = 0.0, cursor = start, largest = 0.0
        for (left, right) in zip(samples, samples.dropFirst()) {
            guard left.run == right.run, let v0 = left.speed, let v1 = right.speed else { continue }
            let dt = right.timestamp - left.timestamp
            let lo = max(start, left.timestamp), hi = min(end, right.timestamp)
            guard dt > 0, dt <= 1, hi > lo else { continue }
            let a = v0 + (v1 - v0) * (lo - left.timestamp) / dt
            let b = v0 + (v1 - v0) * (hi - left.timestamp) / dt
            meters += (a + b) * 0.5 * (hi - lo)
            covered += hi - lo
            largest = max(largest, lo - cursor); cursor = hi
        }
        return DistanceSummary(meters: meters, duration: end - start, coveredSeconds: covered,
            longestGap: max(largest, end - cursor))
    }

    public func nearestSample(to timestamp: Double) -> SessionSample? {
        guard !samples.isEmpty else { return nil }
        var lower = 0, upper = samples.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if samples[mid].timestamp < timestamp { lower = mid + 1 } else { upper = mid }
        }
        if lower == 0 { return samples[0] }
        if lower == samples.count { return samples.last }
        return timestamp - samples[lower - 1].timestamp <= samples[lower].timestamp - timestamp ? samples[lower - 1] : samples[lower]
    }

    /// Display reduction only. Selection, distance, diagnostics and exported raw data use full samples.
    public func plotSamples(limit: Int = 1200) -> [SessionSample] {
        guard samples.count > max(8, limit) else { return samples }
        let width = max(1, Int(ceil(Double(samples.count) / Double(max(2, limit / 4)))))
        var result: [SessionSample] = []
        for start in stride(from: 0, to: samples.count, by: width) {
            let end = min(samples.count, start + width)
            let indices = Array(start..<end)
            let low = indices.min { (samples[$0].speed ?? .infinity) < (samples[$1].speed ?? .infinity) }!
            let high = indices.max { (samples[$0].speed ?? -.infinity) < (samples[$1].speed ?? -.infinity) }!
            for index in Set([start, end - 1, low, high]).sorted() { result.append(samples[index]) }
        }
        return result
    }

    /// Streaming JSONL reader: no full raw-file copy or retained high-rate raw-event array.
    public static func load(url: URL) throws -> SessionReport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        var report = SessionReport()
        var replay = SpeedReplay()
        var recorded = false, mustBreak = false
        var previousReceipt = -Double.infinity
        var previousSample: SessionSample?
        var run = 0, cumulative = 0.0
        var latestMotion: RawMotion?, latestAccelerometer: VectorSample?, latestGyroscope: VectorSample?, latestMagnetometer: VectorSample?
        var latestLocation: LocationDetails?, latestSpeed: SpeedObservation?
        var latestPressure: Double?, latestAltitude: Double?
        var pending = Data()
        func ingest(_ data: Data) throws {
            guard !data.isEmpty else { return }
            if report.eventCount % 1000 == 0 { try Task.checkCancellation() }
            guard let event = try? decoder.decode(ReplayEvent.self, from: data), event.receivedAt.isFinite,
                  event.receivedAt >= previousReceipt else {
                report.malformedLines += 1; mustBreak = true; return
            }
            previousReceipt = event.receivedAt
            if report.eventCount == 0 { report.startTime = event.receivedAt; report.wallStart = event.wallTime }
            report.endTime = event.receivedAt; report.wallEnd = event.wallTime ?? report.wallEnd
            report.eventCount += 1
            if let metadata = event.metadata {
                report.metadata.merge(metadata) { _, new in new }
                if metadata["sensorMode"] == "mounted" { replay = SpeedReplay(mode: .mounted) }
                if metadata["schemaVersion"] == "2" { recorded = true }
            }
            if let marker = event.marker {
                let time = marker.timestamp.flatMap { $0.isFinite && $0 >= report.startTime && $0 <= event.receivedAt ? $0 : nil }
                report.markers.append(SessionMarker(marker: marker, timestamp: time ?? event.receivedAt))
            }
            if let candidate = event.railCandidate { report.railCandidates.append(candidate) }
            if let resolution = event.railResolution { report.railResolutions.append(resolution) }
            if event.lifecycle == "recordingEnded" { report.endedNormally = true }
            if let error = event.sensorError, report.sensorErrors.count < 30 { report.sensorErrors.append(error) }
            func count(_ name: String, _ timestamp: Double) {
                report.sensorStats[name, default: SensorStatistics()].ingest(time: timestamp, receivedAt: event.receivedAt)
            }
            if let speed = event.speed { latestSpeed = speed; count("location", speed.timestamp) }
            if let location = event.locationDetails { latestLocation = location }
            if let motion = event.rawMotion { latestMotion = motion; count("deviceMotion", motion.timestamp ?? event.receivedAt) }
            if let value = event.accelerometer { latestAccelerometer = value; count("accelerometer", value.timestamp) }
            if let value = event.gyroscope { latestGyroscope = value; count("gyroscope", value.timestamp) }
            if let value = event.magnetometer { latestMagnetometer = value; count("magnetometer", value.timestamp) }
            if let pressure = event.pressure { latestPressure = pressure; latestAltitude = event.relativeAltitude; count("altimeter", event.altitudeTimestamp ?? event.receivedAt) }
            if event.reset == true || event.resetSpeedOnly == true { mustBreak = true }
            let estimate: SpeedEstimate
            if let original = event.recordedEstimate {
                estimate = original; recorded = true
            } else if !recorded, let output = try? replay.consume(event) {
                estimate = output.estimate
            } else { return }
            let speed = estimate.speed.flatMap { $0.isFinite && $0 >= 0 && estimate.state != .unavailable ? $0 : nil }
            guard estimate.timestamp.isFinite, estimate.timestamp >= (report.samples.last?.timestamp ?? -.infinity) else {
                report.malformedLines += 1; mustBreak = true; return
            }
            if mustBreak || previousSample == nil || estimate.timestamp - previousSample!.timestamp > 1 { run += 1 }
            if !mustBreak, let previousSample, let v0 = previousSample.speed, let speed {
                let dt = estimate.timestamp - previousSample.timestamp
                if dt > 0, dt <= 1 { cumulative += (v0 + speed) * 0.5 * dt }
            }
            let sample = SessionSample(id: report.samples.count, timestamp: estimate.timestamp, speed: speed,
                uncertainty: estimate.uncertainty, state: estimate.state, source: estimate.source, observationAge: estimate.observationAge,
                cumulativeMeters: cumulative, run: run, diagnostics: event.diagnostics, motion: latestMotion,
                accelerometer: latestAccelerometer, gyroscope: latestGyroscope, magnetometer: latestMagnetometer,
                location: latestLocation, rawSpeed: latestSpeed, pressure: latestPressure, relativeAltitude: latestAltitude,
                batteryLevel: event.batteryLevel, thermalState: event.thermalState)
            report.samples.append(sample)
            previousSample = speed == nil ? nil : sample
            mustBreak = false
        }
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let end = pending[start...].firstIndex(of: 10) {
                try ingest(Data(pending[start..<end])); start = end + 1
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { try ingest(pending) }
        report.markers.sort { $0.timestamp < $1.timestamp }
        return report
    }
}
