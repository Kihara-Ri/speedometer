import UIKit
import SwiftUI

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // Keep the active session alive across scene disconnection/reconnection in the same process.
    lazy var model: SpeedometerModel = {
        var url: URL?
        if ProcessInfo.processInfo.arguments.contains("--record-sensors") {
            let name = "session-debug-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jsonl"
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        }
        return SpeedometerModel(recordingURL: url)
    }()
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Measurement", sessionRole: session.role)
        configuration.delegateClass = MeasurementSceneDelegate.self
        return configuration
    }
}

@MainActor
final class MeasurementSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var model: SpeedometerModel?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let model = delegate.model
        self.model = model
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: SpeedometerView(model: model))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        model.start()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { model?.suspend() }
    func sceneWillEnterForeground(_ scene: UIScene) { model?.resume() }
    func sceneDidDisconnect(_ scene: UIScene) { window = nil }
}
