import Darwin
import UIKit

private let fixtureCrashNotificationPrefix =
    "com.iosuse.playfixture.self-sigkill."

private func fixtureCrashNotificationCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    _ = center
    _ = observer
    _ = name
    _ = object
    _ = userInfo
    _ = Darwin.kill(Darwin.getpid(), SIGKILL)
}

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
    private var crashNotificationName: CFNotificationName?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]?
    ) -> Bool {
        _ = application
        _ = launchOptions
        registerCrashNotification()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        _ = application
        guard let crashNotificationName else {
            return
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            crashNotificationName,
            nil
        )
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

    private func registerCrashNotification() {
        guard let rawSessionID = ProcessInfo.processInfo.environment[
            "IOS_USE_PLAY_SESSION_ID"
        ],
        let sessionID = UUID(uuidString: rawSessionID)?.uuidString else {
            return
        }
        let name = CFNotificationName(
            (fixtureCrashNotificationPrefix + sessionID) as CFString
        )
        crashNotificationName = name
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            fixtureCrashNotificationCallback,
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }
}
