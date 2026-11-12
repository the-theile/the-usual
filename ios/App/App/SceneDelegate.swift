import UIKit
import WebKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // This is the app's only window. Info.plist must not name a scene or main
        // storyboard: UIKit would build a second window around Main.storyboard's
        // own bridge. That was the likely cause of RaveFAM's iPad "taps do
        // nothing" App Review rejection (2.1(a)).
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = UsualBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

// The Terms and Privacy pages load in this webview with no browser chrome, so
// give them the native edge swipe-back to return to the app. Off on the app
// itself ("/", hash routes): a stray swipe there would step back through
// screens, e.g. onto a used invite link.
class UsualBridgeViewController: CAPBridgeViewController {
    private var urlObservation: NSKeyValueObservation?

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        urlObservation = webView?.observe(\.url, options: [.initial, .new]) { webView, _ in
            let path = webView.url?.path ?? "/"
            webView.allowsBackForwardNavigationGestures = !(path == "/" || path.isEmpty || path.hasPrefix("/tender/"))
        }
    }
}
