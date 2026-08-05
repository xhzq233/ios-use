import CoreGraphics
import Foundation
import UIKit

/// Headless, compile-time replacement for PlayTools' plist-backed settings.
///
/// The property surface deliberately matches the pinned PlaySettings selectors
/// consumed by PlayLoader, PlayScreen and NSObject+Swizzle.  It is not a
/// configurable profile: every value comes from IOSUsePlayDevice.h or the
/// fixed headless policy.
@objc(PlaySettings)
@objcMembers
public final class PlaySettings: NSObject {
    public static let shared = PlaySettings()

    public let deviceModel = String(cString: IOSUsePlayDeviceProductType())
    public let oemID = String(cString: IOSUsePlayDeviceHardwareTarget())
    public let customScaler = Double(IOSUsePlayDeviceScale)
    public let adaptiveDisplay = true
    public let inverseScreenValues = false
    public let resizableWindow = false
    public let fixedIdentityCoordinates = true
    public let notch = true
    public let windowFixMethod = 0
    public let playChain = true
    public let playChainDebugging = false
    public let blockSleepSpamming = false
    public let checkMicPermissionSync = false
    public let limitMotionUpdateFrequency = false
    public let disableBuiltinMouse = false
    public let ignoreUnityKeyboardInitializationError = false
    public var windowSizeWidth = CGFloat(IOSUsePlayDeviceLogicalWidth)
    public var windowSizeHeight = CGFloat(IOSUsePlayDeviceLogicalHeight)

    private override init() {
        super.init()
    }
}

@objc(PlayInfo)
@objcMembers
public final class PlayInfo: NSObject {
    public static let isUnrealEngine = false
}

/// Pinned AKPluginLoader semantics with the external bundle removed.  The
/// plugin is compiled into this Runtime, so there is still one injected load
/// command and no second bundle/framework.
final class AKInterface {
    static var shared: Plugin?

    static func initialize() {
        if shared == nil {
            shared = AKPlugin()
        }
    }
}

/// Objective-C entry point that keeps Runtime automation on the pinned
/// PlayTools `Toucher` frontend instead of bypassing it and calling
/// `PTFakeMetaTouch` directly. The Runtime owns gesture timing and target
/// resolution; Toucher retains upstream touch-id lifecycle and delivery.
@objc(IOSUsePlayTouchBridge)
public final class IOSUsePlayTouchBridge: NSObject {
    @objc(sendAtPoint:phase:touchID:window:view:)
    public static func send(
        at point: CGPoint,
        phase rawPhase: Int,
        touchID: NSNumber?,
        window: UIWindow,
        view: UIView
    ) -> NSNumber? {
        guard let phase = UITouch.Phase(rawValue: rawPhase) else {
            return nil
        }
        var identifier = touchID?.intValue
        Toucher.touchcam(
            point: point,
            phase: phase,
            tid: &identifier,
            preferredWindow: window,
            preferredView: view,
            actionName: "ios-use",
            keyName: "runtime"
        )
        return identifier.map { NSNumber(value: $0) }
    }
}

@objc(PlayCover)
@objcMembers
public final class PlayCover: NSObject {
    public static func launch() {
        AKInterface.initialize()
        PlayScreen.shared.initialize()
        IOSUsePlayAppKitBridge.scheduleFixedWindowConfiguration()
    }

    /// The headless Runtime intentionally has no menu editor.
    public static func initMenu(menu _: NSObject) {}
}
