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
        let replacement = LifecycleWindow(windowScene: windowScene)
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

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        LifecycleTrace.record("scene.updated", extra: [
            "previousScene": [previousCoordinateSpace.bounds.width, previousCoordinateSpace.bounds.height]
        ])
    }

    private func postURL(_ url: URL) {
        if url.host == "lifecycle" {
            if url.path == "/reset" { LifecycleTrace.reset() }
            if url.path == "/finish" { LifecycleTrace.finish() }
            #if targetEnvironment(macCatalyst)
            if url.path == "/resize", let scene = window?.windowScene,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let values = components.queryItems ?? []
                let width = Double(values.first { $0.name == "width" }?.value ?? "") ?? 800
                let height = Double(values.first { $0.name == "height" }?.value ?? "") ?? 750
                if #available(macCatalyst 16.0, *) {
                    var frame = scene.effectiveGeometry.systemFrame
                    frame.size = CGSize(width: width, height: height)
                    scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { error in
                        LifecycleTrace.record("resize.error", extra: ["message": error.localizedDescription])
                    }
                }
            }
            #endif
            return
        }
        NotificationCenter.default.post(
            name: .fixtureOpenURL,
            object: url.absoluteString
        )
    }
}
