import UIKit
import SwiftUI

// Separate simulator host. Replays controlled inputs through the real core and renders
// the shipping card; it does not inject synthetic sensor data into the shipping service.
@main
@MainActor
final class RailUITestDelegate: UIResponder, UIApplicationDelegate {}

@MainActor
final class MeasurementSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RailTestView())
        window.makeKeyAndVisible(); self.window = window
        Task { await runChecks() }
    }

    private func runChecks() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var passed: [String] = []
        var failure: String?
        do {
            for answer in [RailArrivalAnswer.confirmed, .denied] {
                let scenario = RailScenario()
                guard let candidate = scenario.current else { throw CheckFailure.missingCandidate }
                if answer == .confirmed {
                    for (name, width, size) in [("small", 343.0, DynamicTypeSize.large), ("accessibility", 288.0, DynamicTypeSize.accessibility2)] {
                        let card = RailArrivalCard(candidate: candidate, respond: scenario.respond)
                            .frame(width: width).environment(\.colorScheme, .dark).environment(\.dynamicTypeSize, size)
                        let host = UIHostingController(rootView: card)
                        host.loadViewIfNeeded()
                        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                        guard size.width <= width + 0.5, size.height > 0, size.height < 1000 else {
                            throw CheckFailure.layoutFailed
                        }
                    }
                    passed.append("shipping SwiftUI card fits small and accessibility widths")
                }
                scenario.respond(id: candidate.id, answer: answer)
                await scenario.saveTask?.value
                guard scenario.current == nil, let url = scenario.journalURL else { throw CheckFailure.responseFailed }
                let report = try SessionReport.load(url: url)
                guard report.railCandidates.count == 1, report.railResolutions.count == 1,
                      report.railResolutions.first?.answer == answer,
                      report.railResolutions.first?.stoppedAt == 114,
                      report.railResolutions.first?.timestamp == 130 else { throw CheckFailure.responseFailed }
                passed.append("\(answer.rawValue) callback persists associated feedback and original stop time")
            }
        } catch { failure = String(describing: error) }
        let result: [String: Any] = ["passed": passed, "failure": failure as Any? ?? NSNull()]
        try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
            .write(to: root.appendingPathComponent("rail-ui-checks.json"), options: .atomic)
    }
    private enum CheckFailure: Error { case missingCandidate, layoutFailed, responseFailed }
}

@MainActor
@Observable
final class RailScenario {
    var current: RailArrivalCandidate?
    var answer = "等待点击"
    private var replay = SpeedReplay()
    private var time = 0.0
    private var journal: SensorJournal?
    private(set) var journalURL: URL?
    private(set) var saveTask: Task<Void, Never>?
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { reset() }
    func reset() {
        replay = SpeedReplay(); current = nil; answer = "等待点击"
        let url = root.appendingPathComponent("rail-ui-\(UUID().uuidString).jsonl")
        journalURL = url
        journal = try? SensorJournal(url: url)
        for t in 0...129 {
            let i = t % 65
            let speed = i <= 12 ? Double(i) : i <= 37 ? 12 : max(0, 12 - Double(i - 37))
            var event = ReplayEvent(receivedAt: Double(t),
                speed: SpeedObservation(timestamp: Double(t), speed: speed, speedAccuracy: 0.2, horizontalAccuracy: 5),
                rawMotion: RawMotion(acceleration: [0,0,0], gravity: [0,0,-1], rotationRate: [0,0,0],
                                     quaternion: [0,0,0,1], timestamp: Double(t)))
            if let update = try? replay.consume(event) {
                current = update.rail.current
                event.railCandidate = update.rail.created
            }
            journal?.append(event)
        }
        time = 130
    }
    func respond(id: String, answer: RailArrivalAnswer) {
        var event = ReplayEvent(receivedAt: time)
        event.railFeedback = RailArrivalFeedback(candidateID: id, answer: answer)
        guard let output = try? replay.consume(event), let resolution = output.rail.resolved else { return }
        event.railResolution = resolution
        current = output.rail.current
        self.answer = resolution.answer == .confirmed ? "已确认到站" : "已否认"
        journal?.append(event)
        let writer = journal
        saveTask = Task {
            try? await writer?.finish()
            let result: [String: Any] = ["answer": resolution.answer.rawValue, "candidateID": id,
                                       "stoppedAt": resolution.stoppedAt, "respondedAt": time]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("rail-ui-result.json"), options: .atomic)
        }
    }
}

struct RailTestView: View {
    @State private var scenario = RailScenario()
    var body: some View {
        ZStack {
            Palette.bottom.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("到站提示 · 受控回放").font(.title2)
                if let current = scenario.current {
                    RailArrivalCard(candidate: current, respond: scenario.respond)
                }
                Text(scenario.answer).accessibilityIdentifier("railTestResult")
                Button("重播测试行程", action: scenario.reset).buttonStyle(.bordered)
                Text("真实识别器与卡片；此页面属于独立测试应用。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: 375)
        }
        .preferredColorScheme(.dark)
    }
}
