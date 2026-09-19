import UIKit

final class LifecycleWindow: UIWindow {
    override var bounds: CGRect {
        willSet { LifecycleTrace.record("window.bounds.will", extra: ["target": [newValue.width, newValue.height]]) }
        didSet { LifecycleTrace.record("window.bounds.did") }
    }

    override var frame: CGRect {
        willSet { LifecycleTrace.record("window.frame.will", extra: ["target": [newValue.width, newValue.height]]) }
        didSet { LifecycleTrace.record("window.frame.did") }
    }
}

// Opt-in, App-owned observations. No Runtime callbacks are synthesized here.
@objc(FixtureLifecycleTrace)
final class LifecycleTrace: NSObject {
    private static var events: [[String: Any]] = []
    private static var enabled = false
    private static var started: TimeInterval = 0
    private static var initialTraits: UITraitCollection?
    private static var orientationObserver: NSObjectProtocol?

    @objc static func reset() {
        events = []
        started = ProcessInfo.processInfo.systemUptime
        enabled = true
        initialTraits = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.traitCollection
        if orientationObserver == nil {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil, queue: .main
            ) { _ in record("orientation.notification") }
        }
        record("trace.begin")
    }

    @objc static func json() -> String {
        let data = try! JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @objc static func presentSheet() {
        let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
        let sheet = UINavigationController(rootViewController: UIKitFixtureViewController(sceneGeneration: 0))
        sheet.modalPresentationStyle = .formSheet
        root?.present(sheet, animated: true)
    }

    @objc static func dismissSheet() {
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.dismiss(animated: true)
    }

    @objc static func finish() {
        record("trace.end")
        enabled = false
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lifecycle.json")
        try? json().write(to: url, atomically: true, encoding: .utf8)
    }

    static func record(_ event: String, controller: UIViewController? = nil,
                       extra: [String: Any] = [:]) {
        guard enabled else { return }
        let window = (UIApplication.shared.delegate as? AppDelegate)?.window
        let controller = controller ?? window?.rootViewController
        let view = controller?.viewIfLoaded
        func size(_ value: CGSize?) -> [CGFloat] {
            [value?.width ?? 0, value?.height ?? 0]
        }
        func traits(_ value: UITraitCollection?) -> [Any] {
            [value?.horizontalSizeClass.rawValue ?? 0,
             value?.verticalSizeClass.rawValue ?? 0,
             value?.userInterfaceIdiom.rawValue ?? -1,
             value?.displayScale ?? 0]
        }
        let inset = view?.safeAreaInsets ?? .zero
        var row: [String: Any] = [
            "event": event, "index": events.count,
            "ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "controller": controller.map { String(describing: type(of: $0)) } ?? "none",
            "screen": size(window?.screen.bounds.size),
            "scene": size(window?.windowScene?.coordinateSpace.bounds.size),
            "minimumSize": size(window?.windowScene?.sizeRestrictions?.minimumSize),
            "maximumSize": size(window?.windowScene?.sizeRestrictions?.maximumSize),
            "window": size(window?.bounds.size), "view": size(view?.bounds.size),
            "controllerTraits": traits(controller?.traitCollection),
            "retainedTraits": traits(initialTraits),
            "viewTraits": traits(view?.traitCollection),
            "safeArea": [inset.top, inset.left, inset.bottom, inset.right],
            "physicalOrientation": UIDevice.current.orientation.rawValue,
            "interfaceOrientation": window?.windowScene?.interfaceOrientation.rawValue ?? 0,
            "coordinator": controller?.transitionCoordinator != nil,
        ]
        if let scroll = view?.subviews.compactMap({ $0 as? UIScrollView }).first {
            row["scrollOffset"] = [scroll.contentOffset.x, scroll.contentOffset.y]
            row["scrollContent"] = size(scroll.contentSize)
            row["scrollBounds"] = size(scroll.bounds.size)
        }
        row.merge(extra) { _, new in new }
        events.append(row)
    }

    static func transition(_ controller: UIViewController, to size: CGSize,
                           coordinator: UIViewControllerTransitionCoordinator) {
        record("transition.begin", controller: controller,
               extra: ["target": [size.width, size.height]])
        coordinator.animate(alongsideTransition: { _ in
            record("transition.alongside", controller: controller)
        }, completion: { context in
            record("transition.complete", controller: controller,
                   extra: ["cancelled": context.isCancelled])
        })
    }
}
