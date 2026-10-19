import UIKit

// Isolated simulator host: compiles the real app model/service and real disk journal.
// No sensor or service doubles. It does not run inside the shipping application.
@main
@MainActor
final class FlowTestDelegate: UIResponder, UIApplicationDelegate {}

@MainActor
final class MeasurementSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible(); self.window = window
        Task { await run() }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AppFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func waitForSave(_ model: SpeedometerModel) async throws {
        for _ in 0..<100 {
            if !model.isRecording && !model.isFinalizingRecording { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(false, "recording never finished saving")
    }

    private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var passed = [String]()
        var failure: String?
        do {
            let model = SpeedometerModel()
            model.start()
            try check(model.isRecording, "ordinary measurement start did not create a recording")
            passed.append("automatic recording on ordinary start")
            model.addMarker(kind: "departure", note: "test station")
            model.start()
            try check(model.markers.contains { $0.note == "test station" }, "duplicate start reset the active journey")
            model.suspend(); model.resume()
            model.stop()
            // Repeated start while flushing must not lose the file or attach to a closing journal.
            model.start()
            try await waitForSave(model)
            try check(model.recordingError == nil, "recording reported a write failure")
            guard let firstURL = model.lastExport else { throw NSError(domain: "AppFlow", code: 2) }
            let first = try Data(contentsOf: firstURL)
            let events = try first.split(separator: 10).map { try JSONDecoder().decode(ReplayEvent.self, from: Data($0)) }
            try check(events.contains { $0.marker?.note == "test station" }, "station marker missing from saved journey")
            try check(events.filter { $0.lifecycle == "recordingEnded" }.count == 1, "stop did not save one completed journey")
            try check(events.contains { $0.lifecycle == "backgroundEntered" } && events.contains { $0.lifecycle == "foregroundEntered" }, "foreground return lost journey lifecycle")
            model.refreshRecordings()
            try check(model.recordings.contains { $0.url == firstURL }, "completed journey not visible in history")
            passed.append("stop saves readable completed journey with station and lifecycle events")
            model.start()
            try check(model.isRecording, "restart did not record a new journey")
            model.stop(); try await waitForSave(model)
            try check(model.lastExport != firstURL, "restart reused previous recording file")
            try check(try Data(contentsOf: firstURL) == first, "restart modified previous raw data")
            passed.append("restart preserves previous data and uses a new file")

            let blocker = root.appendingPathComponent("blocked-\(UUID())")
            try Data([0]).write(to: blocker)
            let broken = SpeedometerModel(recordingURL: blocker.appendingPathComponent("session.jsonl"))
            broken.start()
            try check(!broken.isRecording && !broken.isActive && broken.recordingError != nil,
                      "write failure allowed measurement without a recording")
            passed.append("write failure prevents unrecorded measurement")
        } catch { failure = error.localizedDescription }
        let result: [String: Any] = ["passed": passed, "failure": failure as Any? ?? NSNull()]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("flow-result.json"), options: .atomic)
    }
}
