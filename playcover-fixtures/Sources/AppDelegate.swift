import UIKit

extension Notification.Name {
    static let fixtureOpenURL = Notification.Name(
        "com.iosuse.playfixture.open-url"
    )
    static let fixtureReplaceScene = Notification.Name(
        "com.iosuse.playfixture.replace-scene"
    )
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]?
    ) -> Bool {
        _ = application
        _ = launchOptions
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession:
            UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        _ = application
        _ = options
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        _ = app
        _ = options
        NotificationCenter.default.post(
            name: .fixtureOpenURL,
            object: url.absoluteString
        )
        return true
    }
}
