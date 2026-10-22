import XCTest
@testable import SpeedCore

/// Live capture stores derived estimates beside raw input; replaying the saved file must reproduce them.
final class PipelineParityTests: XCTestCase {
    private func scenario() -> [ReplayEvent] {
        var events: [ReplayEvent] = []
        var header = ReplayEvent(receivedAt: 0)
        header.metadata = ["schemaVersion": "2", "sensorMode": "handheld"]
        events.append(header)
        events.append(ReplayEvent(receivedAt: 0, reset: true))
        events.append(ReplayEvent(receivedAt: 0.01, activitySource: .available))
        var noise: UInt64 = 42
        func jitter() -> Double {
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            return Double(noise >> 11) / 9007199254740992 - 0.5
        }
        func truth(_ t: Double) -> Double {
            let phase = t.truncatingRemainder(dividingBy: 90)
            if phase < 10 { return 0 }
            if phase < 20 { return 1.5 * (phase - 10) }
            if phase < 60 { return 15 }
            if phase < 70 { return 15 - 1.5 * (phase - 60) }
            return 0
        }
        var t = 0.02
        while t < 300 {
            let tick = (t * 50).rounded() / 50
            if Int((tick * 50).rounded()) % 50 == 0 {
                let second = tick
                if Int(second) % 37 == 5 {
                    events.append(ReplayEvent(receivedAt: second, activity: ActivityObservation(
                        timestamp: second, confidence: .high, automotive: truth(second) > 3, stationary: truth(second) <= 3)))
                }
                let spike = Int(second) % 71 == 0 ? 20.0 : 0
                let lag = 0.15 + 0.1 * jitter()
                var speed = ReplayEvent(receivedAt: second + lag, speed: SpeedObservation(
                    timestamp: second, speed: max(0, truth(second) + 0.3 * jitter() + spike),
                    speedAccuracy: 0.5, horizontalAccuracy: 5))
                speed.locationDetails = LocationDetails(wallTime: second, latitude: 35 + truth(second) * second * 1e-7,
                    longitude: 139, altitude: 0, verticalAccuracy: 3, course: 0, courseAccuracy: 5, simulated: false, accessory: false)
                events.append(speed)
                if Int(second) == 150 { events.append(ReplayEvent(receivedAt: second + lag, resetSpeedOnly: true)) }
            }
            if Int((tick * 50).rounded()) % 10 == 0 { events.append(ReplayEvent(receivedAt: tick + 0.2)) }
            let quiet = truth(tick) == 0
            events.append(ReplayEvent(receivedAt: tick + 0.2, rawMotion: RawMotion(
                acceleration: [quiet ? 0.01 : 0.1 * jitter(), 0, 0], gravity: [0, 0, -1],
                rotationRate: [0, 0, quiet ? 0.01 : 0.3 * jitter()], quaternion: [0, 0, 0, 1], timestamp: tick + 0.19)))
            var accelerometer = ReplayEvent(receivedAt: tick + 0.2)
            accelerometer.accelerometer = VectorSample(timestamp: tick + 0.19, values: [0, 0, -1])
            events.append(accelerometer)
            t += 0.02
        }
        return events.sorted { $0.receivedAt < $1.receivedAt }
    }

    func testRecordedEstimatesReplayExactly() throws {
        var live = FusionPipeline()
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        var journal = Data()
        var liveOutputs: [ReplayOutput] = []
        for var event in scenario() {
            liveOutputs.append(live.processForRecording(&event))
            journal.append(try encoder.encode(event)); journal.append(10)
        }
        var replay = SpeedReplay()
        var compared = 0, stationary = 0, measured = 0, created = 0
        for (index, line) in journal.split(separator: 10).enumerated() {
            let event = try ReplayEvent.decode(Data(line))
            let output = try replay.consume(event)
            XCTAssertEqual(output.estimate, liveOutputs[index].estimate, "event \(index)")
            XCTAssertEqual(output.travel, liveOutputs[index].travel, "event \(index)")
            XCTAssertEqual(output.rail.current, liveOutputs[index].rail.current, "event \(index)")
            if let recorded = event.recordedEstimate {
                XCTAssertEqual(recorded, output.estimate, "event \(index)"); compared += 1
            }
            if output.estimate.source == .stationary { stationary += 1 }
            if output.estimate.state == .measured { measured += 1 }
            if output.rail.created != nil { created += 1 }
        }
        // The scenario must exercise the interesting paths, otherwise parity is vacuous.
        XCTAssertGreaterThan(compared, 1000)
        XCTAssertGreaterThan(stationary, 0)
        XCTAssertGreaterThan(measured, 100)
    }

    func testSupplementalEventsCarryNoDerivedEstimate() {
        var pipeline = FusionPipeline()
        var event = ReplayEvent(receivedAt: 1)
        event.gyroscope = VectorSample(timestamp: 1, values: [0, 0, 0])
        _ = pipeline.processForRecording(&event)
        XCTAssertNil(event.recordedEstimate)
        var tick = ReplayEvent(receivedAt: 2)
        _ = pipeline.processForRecording(&tick)
        XCTAssertNotNil(tick.recordedEstimate)
        XCTAssertNotNil(tick.diagnostics)
    }
}
