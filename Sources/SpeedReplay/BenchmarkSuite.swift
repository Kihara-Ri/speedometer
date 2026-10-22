import Foundation
import SpeedCore

/// Multi-seed benchmark through the production `FusionPipeline`, with realistic GNSS delivery lag,
/// misreported accuracy, correlated errors and stop evidence. Scores the estimate shown at receipt
/// time against truth at that same instant, which is what the user actually sees.
private struct SuiteScenario {
    var name: String
    var mounted = false
    var duration = 80.0
    var truth: (Double) -> Double
    var gnssAvailable: (Double) -> Bool = { _ in true }
    /// Actual GNSS speed noise (1σ) vs. the accuracy the receiver reports.
    var noiseSigma = 0.8
    var reportedAccuracy = 0.8
    /// AR(1) correlated error: (σ, τ seconds). nil for white noise only.
    var correlated: (sigma: Double, tau: Double)?
    var spike: (Int) -> Double = { _ in 0 }
    var stopEvidence = false
}

private struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 1 }
    mutating func unit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9007199254740992
    }
    mutating func normal() -> Double { sqrt(-2*log(max(1e-12, unit()))) * cos(2 * .pi * unit()) }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * unit() }
}

struct SuiteReport: Codable {
    var scenario: String
    var seeds: Int
    var meanRMSE: Double
    var worstSeedRMSE: Double
    var p95AbsoluteError: Double
    var maximumError: Double
    var availability: Double
    /// Fraction of available samples with |error| ≤ 1σ / 2σ (ideal ≈ 0.68 / 0.95). Stationary output has no σ.
    var coverage1Sigma: Double?
    var coverage2Sigma: Double?
    var meanUncertainty: Double?
    var rejectedFixesPerSeed: Double
}

private func makeScenarios() -> [SuiteScenario] {
    func brake(_ t: Double) -> Double {
        if t < 10 { return 0 }
        if t < 25 { return 2*(t-10) }
        if t < 35 { return 30 }
        if t < 40 { return 30-6*(t-35) }
        return 0
    }
    func tunnel(_ t: Double) -> Double { t < 20 ? 25 : max(17, 25-2*(t-20)) }
    func stopAndGo(_ t: Double) -> Double {
        if t < 20 { return 0 }
        if t < 35 { return t - 20 }
        if t < 50 { return 15 }
        if t < 60 { return 15 - 1.5*(t-50) }
        return 0
    }
    return [
        SuiteScenario(name: "cruise", truth: { _ in 25 }),
        SuiteScenario(name: "accelerate-brake", truth: brake),
        SuiteScenario(name: "train-high-speed", truth: { min(90, max(0, $0*1.5)) }),
        SuiteScenario(name: "gnss-spikes", truth: { _ in 25 }, spike: { $0 % 17 == 0 ? 45 : 0 }),
        SuiteScenario(name: "tunnel-handheld", truth: tunnel, gnssAvailable: { !($0 > 20 && $0 < 29) }),
        SuiteScenario(name: "tunnel-mounted", mounted: true, truth: tunnel, gnssAvailable: { !($0 > 20 && $0 < 29) }),
        SuiteScenario(name: "stop-and-go", duration: 90, truth: stopAndGo, noiseSigma: 0.5, reportedAccuracy: 0.6, stopEvidence: true),
        SuiteScenario(name: "overconfident-gnss", truth: brake, noiseSigma: 1.6, reportedAccuracy: 0.5),
        SuiteScenario(name: "urban-multipath", truth: { 12 + 3*sin($0/6) }, noiseSigma: 0.4, reportedAccuracy: 0.8,
                      correlated: (1.2, 5)),
    ]
}

private func run(_ scenario: SuiteScenario, seed: UInt64) -> (squared: [Double], absolute: [Double], samples: Int,
                                                              within1: Int, within2: Int, withSigma: Int, sigmaSum: Double, rejected: Int) {
    var rng = Rng(seed: seed)
    var events: [ReplayEvent] = [ReplayEvent(receivedAt: 0, reset: true)]
    if scenario.stopEvidence { events.append(ReplayEvent(receivedAt: 0.001, activitySource: .available)) }
    var correlated = 0.0, distance = 0.0
    let truth = scenario.truth
    let steps = Int(scenario.duration * 20)
    for i in 0...steps {
        let t = Double(i) / 20
        distance += truth(t) / 20
        if i % 20 == 0, scenario.gnssAvailable(t) {
            let second = i / 20
            if let c = scenario.correlated {
                let phi = exp(-1 / c.tau)
                correlated = phi*correlated + sqrt(1 - phi*phi)*c.sigma*rng.normal()
            }
            let raw = max(0, truth(t) + scenario.noiseSigma*rng.normal() + correlated + scenario.spike(second))
            let lag = rng.uniform(0.15...0.6)
            var event = ReplayEvent(receivedAt: t + lag, speed: SpeedObservation(timestamp: t, speed: raw,
                                    speedAccuracy: scenario.reportedAccuracy, horizontalAccuracy: 5))
            if scenario.stopEvidence {
                event.locationDetails = LocationDetails(wallTime: t, latitude: 35 + (distance + 1.5*rng.normal())/111_111,
                    longitude: 139, altitude: 0, verticalAccuracy: 3, course: 0, courseAccuracy: 5,
                    simulated: false, accessory: false, rawHorizontalAccuracy: 5)
            }
            events.append(event)
        }
        if scenario.mounted {
            let acceleration = (truth(t + 0.025) - truth(t - 0.025)) / 0.05
            events.append(ReplayEvent(receivedAt: t + 0.01, motion: MotionObservation(timestamp: t,
                acceleration: acceleration + 0.15 + 0.05*rng.normal(), rotationRate: 0)))
        }
        if scenario.stopEvidence {
            let moving = truth(t) > 0
            let amplitude = moving ? 0.12 : 0.005
            events.append(ReplayEvent(receivedAt: t + 0.01, rawMotion: RawMotion(
                acceleration: [amplitude*rng.normal(), amplitude*rng.normal(), amplitude*rng.normal()], gravity: [0, 0, -1],
                rotationRate: [0, 0, (moving ? 0.1 : 0.005)*rng.normal()], quaternion: [0, 0, 0, 1], timestamp: t)))
            // Activity classification trails reality by about two seconds.
            if i % 40 == 0 {
                let stopped = truth(max(0, t - 2)) == 0 && truth(t) == 0
                events.append(ReplayEvent(receivedAt: t + 0.02, activity: ActivityObservation(timestamp: t + 0.02,
                    confidence: .high, automotive: !stopped, stationary: stopped)))
            }
        }
        if i % 2 == 0 { events.append(ReplayEvent(receivedAt: t + 0.015)) }
    }
    events.sort { $0.receivedAt < $1.receivedAt }
    var pipeline = FusionPipeline(mode: scenario.mounted ? .mounted : .handheld)
    var squared: [Double] = [], absolute: [Double] = []
    var samples = 0, within1 = 0, within2 = 0, withSigma = 0, sigmaSum = 0.0, rejected = 0
    for event in events {
        let output = pipeline.process(event)
        if output.result == .outlier { rejected += 1 }
        guard event.isTick, event.receivedAt >= 5 else { continue }
        samples += 1
        guard let speed = output.estimate.speed else { continue }
        let error = abs(speed - truth(event.receivedAt))
        squared.append(error*error); absolute.append(error)
        if let sigma = output.estimate.uncertainty {
            withSigma += 1; sigmaSum += sigma
            if error <= sigma { within1 += 1 }
            if error <= 2*sigma { within2 += 1 }
        }
    }
    return (squared, absolute, samples, within1, within2, withSigma, sigmaSum, rejected)
}

private extension ReplayEvent {
    var isTick: Bool {
        speed == nil && motion == nil && rawMotion == nil && activity == nil && activitySource == nil && reset == nil
    }
}

func runBenchmarkSuite(seeds: Int = 30) throws {
    var reports: [SuiteReport] = []
    for scenario in makeScenarios() {
        var rmses: [Double] = [], absolute: [Double] = []
        var samples = 0, available = 0, within1 = 0, within2 = 0, withSigma = 0, sigmaSum = 0.0, rejected = 0
        for seed in 1...UInt64(seeds) {
            let r = run(scenario, seed: seed)
            rmses.append(sqrt(r.squared.reduce(0, +) / Double(max(1, r.squared.count))))
            absolute += r.absolute
            samples += r.samples; available += r.squared.count
            within1 += r.within1; within2 += r.within2; withSigma += r.withSigma; sigmaSum += r.sigmaSum
            rejected += r.rejected
        }
        absolute.sort()
        func round(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        reports.append(SuiteReport(scenario: scenario.name, seeds: seeds,
            meanRMSE: round(rmses.reduce(0, +) / Double(seeds)), worstSeedRMSE: round(rmses.max() ?? 0),
            p95AbsoluteError: round(absolute.isEmpty ? 0 : absolute[min(absolute.count - 1, Int(0.95 * Double(absolute.count)))]),
            maximumError: round(absolute.last ?? 0), availability: round(Double(available) / Double(max(1, samples))),
            coverage1Sigma: withSigma > 0 ? round(Double(within1) / Double(withSigma)) : nil,
            coverage2Sigma: withSigma > 0 ? round(Double(within2) / Double(withSigma)) : nil,
            meanUncertainty: withSigma > 0 ? round(sigmaSum / Double(withSigma)) : nil,
            rejectedFixesPerSeed: round(Double(rejected) / Double(seeds))))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(reports)); FileHandle.standardOutput.write(Data([10]))
}
