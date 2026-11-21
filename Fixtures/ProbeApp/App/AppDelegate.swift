import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// One recording model per process, created at launch: a fresh launch always
    /// starts a new session, and a scene reconnect within the process does not.
    let model = ProbeModel()
    /// The log probe (docs/probe-app.md#log-probe), independent of the touch probe.
    let logProbe = LogProbeEmitter()
    /// The permission probe (docs/probe-app.md#permission-probe).
    let permissionProbe = PermissionProbeRequester()
    /// The URL probe (docs/probe-app.md#url-probe).
    let urlProbe = URLProbeReceiver()
    /// The tone probe (docs/probe-app.md#tone-probe), silent unless asked for.
    let toneProbe = ToneProbePlayer()

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
        // `-ProbeList YES` shows the list probe in place of the touch surface.
        let lists = ProbeListViewController.isRequested
        window.rootViewController = lists ? ProbeListViewController() : ProbeViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
        (UIApplication.shared.delegate as? AppDelegate)?.toneProbe.attach(to: window)
        if !lists, let surface = window.rootViewController?.view {
            (UIApplication.shared.delegate as? AppDelegate)?.logProbe.attach(to: surface)
            (UIApplication.shared.delegate as? AppDelegate)?.permissionProbe.attach(to: surface)
            (UIApplication.shared.delegate as? AppDelegate)?.urlProbe.attach(to: surface)
        }
        // A URL that launched the app arrives here, not in `openURLContexts`.
        self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            (UIApplication.shared.delegate as? AppDelegate)?.urlProbe.received(context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.permissionProbe.refresh()
        // Keep the display awake: Manzanero's touch and AX paths require an awake display.
        UIApplication.shared.isIdleTimerDisabled = true
        (UIApplication.shared.delegate as? AppDelegate)?.toneProbe.start()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
        (UIApplication.shared.delegate as? AppDelegate)?.toneProbe.stop()
        model?.flush()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        model?.flush()
    }
}
