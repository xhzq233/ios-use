import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var generation = 0
    private var replacementObserver: NSObjectProtocol?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        _ = session
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        replaceWindow(in: windowScene)
        replacementObserver = NotificationCenter.default.addObserver(
            forName: .fixtureReplaceScene,
            object: nil,
            queue: .main
        ) { [weak self, weak windowScene] _ in
            guard let self, let windowScene else {
                return
            }
            self.replaceWindow(in: windowScene)
        }
        for context in connectionOptions.urlContexts {
            postURL(context.url)
        }
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        _ = scene
        for context in URLContexts {
            postURL(context.url)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        _ = scene
        if let replacementObserver {
            NotificationCenter.default.removeObserver(
                replacementObserver
            )
        }
        replacementObserver = nil
    }

    private func replaceWindow(in windowScene: UIWindowScene) {
        generation += 1
        let oldWindow = window
        let replacement = UIWindow(windowScene: windowScene)
        // Publish the same delegate-window path used by Apps that synchronously
        // read safe area during root viewDidLoad. The replacement must be
        // discoverable before assigning/presenting its root controller.
        window = replacement
        (UIApplication.shared.delegate as? AppDelegate)?.window =
            replacement
        replacement.rootViewController = FixtureTabBarController(
            sceneGeneration: generation
        )
        replacement.makeKeyAndVisible()
        oldWindow?.isHidden = true
    }

    private func postURL(_ url: URL) {
        NotificationCenter.default.post(
            name: .fixtureOpenURL,
            object: url.absoluteString
        )
    }
}
