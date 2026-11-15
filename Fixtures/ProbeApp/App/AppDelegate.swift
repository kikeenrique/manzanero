import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// One recording model per process, created at launch: a fresh launch always
    /// starts a new session, and a scene reconnect within the process does not.
    let model = ProbeModel()

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var model: ProbeModel? { (UIApplication.shared.delegate as? AppDelegate)?.model }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let model else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ProbeViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Keep the display awake: Manzanero's touch and AX paths require an awake display.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
        model?.flush()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        model?.flush()
    }
}
