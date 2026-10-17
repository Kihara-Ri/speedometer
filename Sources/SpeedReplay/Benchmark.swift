import Foundation
import SpeedCore

private struct Noise {
    var seed: UInt64 = 123456789
    mutating func unit() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / 9007199254740992
    }
    mutating func normal() -> Double {
        sqrt(-2*log(max(1e-12, unit()))) * cos(2 * .pi * unit())
    }
}
private struct BenchmarkReport: Codable {
    var scenario: String
    var samples: Int
    var available: Int
    var rawRMSE: Double?
    var estimatedRMSE: Double
    var estimatedAtFixRMSE: Double?
    var heldSpeedRMSEOnAvailableSamples: Double
    var maximumError: Double
    var rejectedFixes: Int
    var predictedSamples: Int
    var unavailableSamples: Int
}

func runBenchmark() throws {
    var reports: [BenchmarkReport] = []
    for scenario in ["constant-noise", "accelerate-brake", "train-high-speed", "gnss-spikes", "tunnel-handheld", "tunnel-mounted"] {
        let mounted = scenario == "tunnel-mounted"
        var engine = SpeedEstimator(mode: mounted ? .mounted : .handheld)
        var noise = Noise()
        var rawSquared = 0.0, filteredSquared = 0.0, maximumError = 0.0
        var fixSquared = 0.0, fixCount = 0, heldSquared = 0.0, lastRaw: Double?
        var rawCount = 0, available = 0, rejected = 0, predictedCount = 0, unavailable = 0, samples = 0
        func truth(_ t: Double) -> Double {
            switch scenario {
            case "accelerate-brake":
                if t < 10 { return 0 }
                if t < 25 { return 2*(t-10) }
                if t < 35 { return 30 }
                if t < 40 { return 30-6*(t-35) }
                return 0
            case "train-high-speed": return min(90, max(0, t*1.5))
            case "tunnel-handheld", "tunnel-mounted": return t < 20 ? 25 : max(17, 25-2*(t-20))
            default: return 25
            }
        }
        for i in 0...800 {
            let t = Double(i)/10
            let tunnel = scenario.hasPrefix("tunnel") && t > 20 && t < 29
            if i % 10 == 0 && !tunnel {
                let error = noise.normal()*0.8 + ((scenario == "gnss-spikes" && i % 170 == 0) ? 45 : 0)
                let raw = max(0, truth(t) + error)
                lastRaw = raw
                let fix = SpeedObservation(timestamp: t, speed: raw, speedAccuracy: 0.8, horizontalAccuracy: 5)
                let result = engine.ingest(fix, receivedAt: t)
                if result == .outlier { rejected += 1 }
                if t >= 5 {
                    rawSquared += pow(raw-truth(t), 2); rawCount += 1
                    if let estimate = engine.estimate(at: t).speed {
                        fixSquared += pow(estimate-truth(t), 2); fixCount += 1
                    }
                }
            }
            if mounted {
                let acceleration = t > 20 && t <= 24 ? -2.0 : 0
                _ = engine.ingest(MotionObservation(timestamp: t, acceleration: acceleration + 0.15 + noise.normal()*0.05,
                                                    rotationRate: 0), receivedAt: t)
            }
            if t >= 5 {
                samples += 1
                let result = engine.estimate(at: t)
                if let speed = result.speed {
                    available += 1
                    let error = abs(speed - truth(t))
                    heldSquared += pow((lastRaw ?? speed) - truth(t), 2)
                    filteredSquared += error*error; maximumError = max(maximumError, error)
                    if result.state == .predicted { predictedCount += 1 }
                } else { unavailable += 1 }
            }
        }
        reports.append(BenchmarkReport(scenario: scenario, samples: samples, available: available,
            rawRMSE: rawCount > 0 ? sqrt(rawSquared/Double(rawCount)) : nil,
            estimatedRMSE: sqrt(filteredSquared/Double(max(1, available))),
            estimatedAtFixRMSE: fixCount > 0 ? sqrt(fixSquared/Double(fixCount)) : nil,
            heldSpeedRMSEOnAvailableSamples: sqrt(heldSquared/Double(max(1, available))), maximumError: maximumError,
            rejectedFixes: rejected, predictedSamples: predictedCount, unavailableSamples: unavailable))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(reports)); FileHandle.standardOutput.write(Data([10]))
}
