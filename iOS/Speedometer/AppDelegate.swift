import UIKit
import SwiftUI

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
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
        var recordingURL: URL?
        if ProcessInfo.processInfo.arguments.contains("--record-sensors") {
            let name = "session-\(Int(Date().timeIntervalSince1970)).jsonl"
            recordingURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        }
        let model = SpeedometerModel(recordingURL: recordingURL)
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
    func sceneDidDisconnect(_ scene: UIScene) { model?.stop() }
}
