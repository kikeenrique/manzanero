import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// One recording model per process, created at launch: a fresh launch always
    /// starts a new session, and a scene reconnect within the process does not.
    let model = ProbeModel()
    /// The log probe (docs/probe-app.md#log-probe), independent of the touch probe.
    let logProbe = LogProbeEmitter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        logProbe.launched()
        return true
    }

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
        if let surface = window.rootViewController?.view {
            (UIApplication.shared.delegate as? AppDelegate)?.logProbe.attach(to: surface)
        }
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
