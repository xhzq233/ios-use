import MetalKit
import SwiftUI
import UIKit
import WebKit

final class FixtureTabBarController: UITabBarController {
    private var lastGeometryDescription: String?
    private let sceneGeneration: Int
    private var fullScreenBottomProbes: [UIButton] = []

    init(sceneGeneration: Int = 0) {
        self.sceneGeneration = sceneGeneration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        sceneGeneration = 0
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Keep the fixture itself deterministic across macOS appearances.
        overrideUserInterfaceStyle = .light
        view.backgroundColor = .systemBackground
        let swiftUIViewController = FixtureHostingController(
            rootView: SwiftUIFixtureView()
        )
        // UIHostingController is transparent on Mac Catalyst, so give the
        // fixture content an explicit light surface.
        swiftUIViewController.view.backgroundColor = .systemBackground
        viewControllers = [
            tab(
                UIKitFixtureViewController(
                    sceneGeneration: sceneGeneration
                ),
                title: "UIKit",
                symbol: "rectangle.3.group",
                identifier: "fixture.tab.uikit"
            ),
            tab(
                swiftUIViewController,
                title: "SwiftUI",
                symbol: "swift",
                identifier: "fixture.tab.swiftui"
            ),
            tab(
                WebFixtureViewController(),
                title: "Web",
                symbol: "globe",
                identifier: "fixture.tab.web"
            ),
            tab(
                MetalFixtureViewController(),
                title: "Metal",
                symbol: "square.stack.3d.up",
                identifier: "fixture.tab.metal"
            ),
        ]
        selectedIndex = 0
        addFullScreenBottomProbe(
            title: "Full BL",
            identifier: "fixture.full.bottom-left",
            trailing: false
        )
        addFullScreenBottomProbe(
            title: "Full BR",
            identifier: "fixture.full.bottom-right",
            trailing: true
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for probe in fullScreenBottomProbes {
            view.bringSubviewToFront(probe)
        }
        recordGeometryIfNeeded()
    }

    @objc private func fullScreenBottomProbeTapped(_ sender: UIButton) {
        guard
            let identifier = sender.accessibilityIdentifier,
            let fixture =
                viewControllers?.first as? UIKitFixtureViewController
        else {
            return
        }
        fixture.recordProbe(identifier)
    }

    private func addFullScreenBottomProbe(
        title: String,
        identifier: String,
        trailing: Bool
    ) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 9)
        button.backgroundColor =
            UIColor.systemBackground.withAlphaComponent(0.82)
        button.accessibilityIdentifier = identifier
        button.addTarget(
            self,
            action: #selector(fullScreenBottomProbeTapped(_:)),
            for: .touchUpInside
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        fullScreenBottomProbes.append(button)

        let horizontalConstraint = trailing
            ? button.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -2
            )
            : button.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 2
            )
        NSLayoutConstraint.activate([
            horizontalConstraint,
            button.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -2
            ),
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 30
            ),
        ])
    }

    private func tab(
        _ viewController: UIViewController,
        title: String,
        symbol: String,
        identifier: String
    ) -> UIViewController {
        let item = UITabBarItem(
            title: title,
            image: UIImage(systemName: symbol),
            tag: 0
        )
        item.accessibilityIdentifier = identifier
        viewController.tabBarItem = item
        return viewController
    }

    private func recordGeometryIfNeeded() {
        guard let window = view.window else {
            return
        }
        let screen = window.screen
        let safeArea = window.safeAreaInsets
        let description = String(
            format: "logical %.0fx%.0f scale %.0f native %.0fx%.0f safe %.0f,%.0f,%.0f,%.0f",
            screen.bounds.width,
            screen.bounds.height,
            screen.scale,
            screen.nativeBounds.width,
            screen.nativeBounds.height,
            safeArea.top,
            safeArea.left,
            safeArea.bottom,
            safeArea.right
        )
        guard description != lastGeometryDescription else {
            return
        }
        lastGeometryDescription = description
        (viewControllers?.first as? UIKitFixtureViewController)?
            .updateGeometryDescription(description)

        let payload: [String: Any] = [
            "logicalWidth": screen.bounds.width,
            "logicalHeight": screen.bounds.height,
            "scale": screen.scale,
            "nativeWidth": screen.nativeBounds.width,
            "nativeHeight": screen.nativeBounds.height,
            "safeAreaTop": safeArea.top,
            "safeAreaLeft": safeArea.left,
            "safeAreaBottom": safeArea.bottom,
            "safeAreaRight": safeArea.right,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }
        try? data.write(
            to: documents.appendingPathComponent("geometry.json"),
            options: .atomic
        )
    }
}

private enum UIKitPopupSemantics {
    static let openIdentifier = "fixture.uikit.popup.open"
    static let openLabel = "Open UIKit Popup"
    static let containerIdentifier = "fixture.uikit.popup"
    static let containerLabel = "UIKit In-Window Popup"
    static let confirmIdentifier = "fixture.uikit.popup.confirm"
    static let confirmLabel = "Confirm and Close"
    static let resultIdentifier = "fixture.uikit.popup.result"
    static let resultLabel = "UIKit Popup Result"
}

final class UIKitFixtureViewController:
    UIViewController,
    UIScrollViewDelegate
{
    private let countLabel = UILabel()
    private let geometryLabel = UILabel()
    private let probeStatusLabel = UILabel()
    private let urlStatusLabel = UILabel()
    private let scrollStatusLabel = UILabel()
    private let longPressStatusLabel = UILabel()
    private let sceneStatusLabel = UILabel()
    private let inputStatusLabel = UILabel()
    private let popupStatusLabel = UILabel()
    private let sceneGeneration: Int
    private var count = 0
    private var inputReturnCount = 0
    private var popupConfirmationCount = 0
    private var popupOverlay: UIControl?

    init(sceneGeneration: Int) {
        self.sceneGeneration = sceneGeneration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        sceneGeneration = 0
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let heading = UILabel()
        heading.text = "UIKit Fixture"
        heading.font = .preferredFont(forTextStyle: .largeTitle)
        heading.accessibilityIdentifier = "fixture.uikit.heading"

        countLabel.text = "Count 0"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        countLabel.accessibilityIdentifier = "fixture.uikit.count"

        geometryLabel.text = "Geometry pending"
        geometryLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        geometryLabel.numberOfLines = 0
        geometryLabel.accessibilityIdentifier = "fixture.uikit.geometry"

        probeStatusLabel.text = "Probe none"
        probeStatusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        probeStatusLabel.accessibilityIdentifier = "fixture.probe.status"

        urlStatusLabel.text = "URL none"
        urlStatusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        urlStatusLabel.accessibilityIdentifier = "fixture.url.status"

        scrollStatusLabel.text = "Scroll y 0"
        scrollStatusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .medium
        )
        scrollStatusLabel.accessibilityIdentifier =
            "fixture.scroll.status"

        longPressStatusLabel.text = "Long press none"
        longPressStatusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .medium
        )
        longPressStatusLabel.accessibilityIdentifier =
            "fixture.longpress.status"

        sceneStatusLabel.text = "Scene \(sceneGeneration)"
        sceneStatusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .medium
        )
        sceneStatusLabel.accessibilityIdentifier =
            "fixture.scene.status"
        sceneStatusLabel.accessibilityValue =
            String(sceneGeneration)

        inputStatusLabel.text = "Input none"
        inputStatusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .medium
        )
        inputStatusLabel.accessibilityIdentifier =
            "fixture.uikit.input-status"

        let increment = UIButton(type: .system)
        increment.setTitle("Increment", for: .normal)
        increment.accessibilityIdentifier = "fixture.uikit.increment"
        increment.addTarget(self, action: #selector(incrementCount), for: .touchUpInside)

        let noOp = UIButton(type: .system)
        noOp.setTitle("No-op Target", for: .normal)
        noOp.accessibilityIdentifier = "fixture.uikit.no-op"

        let showAlert = UIButton(type: .system)
        showAlert.setTitle("Show Alert", for: .normal)
        showAlert.accessibilityIdentifier = "fixture.uikit.alert"
        showAlert.addTarget(self, action: #selector(presentFixtureAlert), for: .touchUpInside)

        let showPopup = UIButton(type: .system)
        showPopup.setTitle(
            UIKitPopupSemantics.openLabel,
            for: .normal
        )
        showPopup.accessibilityIdentifier =
            UIKitPopupSemantics.openIdentifier
        showPopup.accessibilityLabel =
            UIKitPopupSemantics.openLabel
        showPopup.addTarget(
            self,
            action: #selector(presentFixturePopup),
            for: .touchUpInside
        )

        popupStatusLabel.text = "Popup Result: idle"
        popupStatusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .medium
        )
        popupStatusLabel.textAlignment = .center
        popupStatusLabel.numberOfLines = 0
        popupStatusLabel.accessibilityIdentifier =
            UIKitPopupSemantics.resultIdentifier
        popupStatusLabel.accessibilityLabel =
            UIKitPopupSemantics.resultLabel
        popupStatusLabel.accessibilityValue = "idle"

        let input = UITextField()
        input.placeholder = "Fixture Input"
        input.borderStyle = .roundedRect
        input.autocorrectionType = .no
        input.accessibilityIdentifier = "fixture.uikit.input"
        input.addTarget(
            self,
            action: #selector(inputEditingChanged(_:)),
            for: .editingChanged
        )
        input.addTarget(
            self,
            action: #selector(inputDidSubmit(_:)),
            for: .editingDidEndOnExit
        )

        let longPressTarget = UIButton(type: .system)
        longPressTarget.setTitle("Long Press Target", for: .normal)
        longPressTarget.accessibilityIdentifier =
            "fixture.uikit.longpress"
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(longPressRecognized(_:))
        )
        longPress.minimumPressDuration = 0.35
        longPressTarget.addGestureRecognizer(longPress)

        let replaceScene = UIButton(type: .system)
        replaceScene.setTitle("Replace Scene Window", for: .normal)
        replaceScene.accessibilityIdentifier =
            "fixture.scene.replace"
        replaceScene.addTarget(
            self,
            action: #selector(replaceSceneWindow),
            for: .touchUpInside
        )

        let scrollEnd = UILabel()
        scrollEnd.text = "Scroll Target End"
        scrollEnd.textAlignment = .center
        scrollEnd.accessibilityIdentifier = "fixture.scroll.end"

        let spacer = UIView()
        spacer.heightAnchor.constraint(
            equalToConstant: 820
        ).isActive = true

        let stack = UIStackView(
            arrangedSubviews: [
                heading,
                geometryLabel,
                probeStatusLabel,
                urlStatusLabel,
                scrollStatusLabel,
                longPressStatusLabel,
                sceneStatusLabel,
                countLabel,
                increment,
                noOp,
                showAlert,
                showPopup,
                popupStatusLabel,
                inputStatusLabel,
                input,
                longPressTarget,
                replaceScene,
                spacer,
                scrollEnd,
            ]
        )
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier =
            "fixture.uikit.scroll"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            scrollView.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 90
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -120
            ),
            stack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 28
            ),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -28
            ),
            stack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -56
            ),
        ])

        addScreenProbe(
            title: "Full TL",
            identifier: "fixture.full.top-left",
            horizontal: view.leadingAnchor,
            vertical: view.topAnchor,
            trailing: false,
            bottom: false
        )
        addScreenProbe(
            title: "Full TR",
            identifier: "fixture.full.top-right",
            horizontal: view.trailingAnchor,
            vertical: view.topAnchor,
            trailing: true,
            bottom: false
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fixtureURLDidOpen(_:)),
            name: .fixtureOpenURL,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func incrementCount() {
        count += 1
        countLabel.text = "Count \(count)"
    }

    func updateGeometryDescription(_ description: String) {
        geometryLabel.text = description
        geometryLabel.accessibilityLabel = description
    }

    @objc private func presentFixtureAlert() {
        let alert = UIAlertController(
            title: "Fixture Alert",
            message: "Alert actions exercise z-order and touch routing.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Confirm", style: .default) { [weak self] _ in
                self?.countLabel.text = "Alert Confirmed"
            }
        )
        present(alert, animated: false)
    }

    @objc private func presentFixturePopup() {
        guard
            popupOverlay == nil,
            let hostWindow = view.window
        else {
            return
        }

        popupStatusLabel.text = "Popup Result: open"
        popupStatusLabel.accessibilityValue = "open"
        popupStatusLabel.backgroundColor =
            UIColor.systemYellow.withAlphaComponent(0.32)

        let overlay = UIControl()
        overlay.backgroundColor =
            UIColor.black.withAlphaComponent(0.58)
        overlay.accessibilityViewIsModal = true
        overlay.clipsToBounds = true
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = UIColor(
            red: 0.19,
            green: 0.16,
            blue: 0.48,
            alpha: 1
        )
        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        card.isAccessibilityElement = false
        card.shouldGroupAccessibilityChildren = true
        card.accessibilityIdentifier =
            UIKitPopupSemantics.containerIdentifier
        card.accessibilityLabel =
            UIKitPopupSemantics.containerLabel
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = UIKitPopupSemantics.containerLabel
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        title.numberOfLines = 0
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = UILabel()
        detail.text =
            "This modal remains inside the UIKit window."
        detail.textColor = UIColor.white.withAlphaComponent(0.86)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.translatesAutoresizingMaskIntoConstraints = false

        let confirm = UIButton(type: .system)
        confirm.setTitle(
            UIKitPopupSemantics.confirmLabel,
            for: .normal
        )
        confirm.setTitleColor(
            UIColor(
                red: 0.19,
                green: 0.16,
                blue: 0.48,
                alpha: 1
            ),
            for: .normal
        )
        confirm.titleLabel?.font = .preferredFont(
            forTextStyle: .headline
        )
        confirm.backgroundColor = .white
        confirm.layer.cornerRadius = 16
        confirm.accessibilityIdentifier =
            UIKitPopupSemantics.confirmIdentifier
        confirm.accessibilityLabel =
            UIKitPopupSemantics.confirmLabel
        confirm.addTarget(
            self,
            action: #selector(confirmFixturePopup),
            for: .touchUpInside
        )
        confirm.translatesAutoresizingMaskIntoConstraints = false

        hostWindow.addSubview(overlay)
        overlay.addSubview(card)
        card.addSubview(title)
        card.addSubview(confirm)
        card.addSubview(detail)
        popupOverlay = overlay

        let safeArea = hostWindow.safeAreaLayoutGuide
        let cardWidth = card.widthAnchor.constraint(
            equalTo: overlay.widthAnchor,
            constant: -48
        )
        cardWidth.priority = .defaultHigh
        let confirmWidth = confirm.widthAnchor.constraint(
            equalTo: card.widthAnchor,
            constant: -48
        )
        confirmWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(
                equalTo: safeArea.leadingAnchor
            ),
            overlay.trailingAnchor.constraint(
                equalTo: safeArea.trailingAnchor
            ),
            overlay.topAnchor.constraint(
                equalTo: safeArea.topAnchor
            ),
            overlay.bottomAnchor.constraint(
                equalTo: safeArea.bottomAnchor
            ),
            card.centerXAnchor.constraint(
                equalTo: overlay.centerXAnchor
            ),
            card.centerYAnchor.constraint(
                equalTo: overlay.centerYAnchor
            ),
            card.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.leadingAnchor,
                constant: 24
            ),
            card.trailingAnchor.constraint(
                lessThanOrEqualTo: overlay.trailingAnchor,
                constant: -24
            ),
            card.topAnchor.constraint(
                greaterThanOrEqualTo: overlay.topAnchor,
                constant: 24
            ),
            card.bottomAnchor.constraint(
                lessThanOrEqualTo: overlay.bottomAnchor,
                constant: -24
            ),
            card.widthAnchor.constraint(
                lessThanOrEqualToConstant: 360
            ),
            card.heightAnchor.constraint(equalToConstant: 252),
            cardWidth,
            title.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: 24
            ),
            title.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -24
            ),
            title.topAnchor.constraint(
                equalTo: card.topAnchor,
                constant: 24
            ),
            title.bottomAnchor.constraint(
                lessThanOrEqualTo: confirm.topAnchor,
                constant: -16
            ),
            confirm.centerXAnchor.constraint(
                equalTo: card.centerXAnchor
            ),
            confirm.centerYAnchor.constraint(
                equalTo: card.centerYAnchor
            ),
            confirm.leadingAnchor.constraint(
                greaterThanOrEqualTo: card.leadingAnchor,
                constant: 24
            ),
            confirm.trailingAnchor.constraint(
                lessThanOrEqualTo: card.trailingAnchor,
                constant: -24
            ),
            confirm.widthAnchor.constraint(
                lessThanOrEqualToConstant: 280
            ),
            confirm.heightAnchor.constraint(equalToConstant: 68),
            confirmWidth,
            detail.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: 24
            ),
            detail.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -24
            ),
            detail.topAnchor.constraint(
                equalTo: confirm.bottomAnchor,
                constant: 16
            ),
            detail.bottomAnchor.constraint(
                lessThanOrEqualTo: card.bottomAnchor,
                constant: -20
            ),
        ])

        hostWindow.layoutIfNeeded()
        UIAccessibility.post(
            notification: .screenChanged,
            argument: confirm
        )
    }

    @objc private func confirmFixturePopup() {
        guard let overlay = popupOverlay else {
            return
        }
        popupConfirmationCount += 1
        popupOverlay = nil
        overlay.removeFromSuperview()
        popupStatusLabel.text =
            "Popup Result: confirmed \(popupConfirmationCount)"
        popupStatusLabel.accessibilityValue =
            "confirmed \(popupConfirmationCount)"
        popupStatusLabel.backgroundColor =
            UIColor.systemGreen.withAlphaComponent(0.34)
        UIAccessibility.post(
            notification: .screenChanged,
            argument: popupStatusLabel
        )
    }

    @objc private func inputEditingChanged(_ sender: UITextField) {
        let value = sender.text ?? ""
        inputStatusLabel.text = "Input value \(value)"
        inputStatusLabel.accessibilityValue = value
    }

    @objc private func inputDidSubmit(_ sender: UITextField) {
        inputReturnCount += 1
        let value = sender.text ?? ""
        inputStatusLabel.text =
            "Input return \(inputReturnCount) \(value)"
        inputStatusLabel.accessibilityValue =
            "return \(inputReturnCount) \(value)"
    }

    @objc private func edgeProbeTapped(_ sender: UIButton) {
        recordProbe(sender.accessibilityIdentifier ?? "unknown")
    }

    func recordProbe(_ identifier: String) {
        probeStatusLabel.text = "Probe \(identifier)"
        probeStatusLabel.accessibilityValue = identifier
    }

    @objc private func longPressRecognized(
        _ recognizer: UILongPressGestureRecognizer
    ) {
        guard recognizer.state == .began else {
            return
        }
        longPressStatusLabel.text = "Long press recognized"
        longPressStatusLabel.accessibilityValue = "recognized"
    }

    @objc private func replaceSceneWindow() {
        NotificationCenter.default.post(
            name: .fixtureReplaceScene,
            object: nil
        )
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let value = Int(scrollView.contentOffset.y.rounded())
        scrollStatusLabel.text = "Scroll y \(value)"
        scrollStatusLabel.accessibilityValue = String(value)
    }

    @objc private func fixtureURLDidOpen(_ notification: Notification) {
        guard let value = notification.object as? String else {
            return
        }
        urlStatusLabel.text = "URL \(value)"
        urlStatusLabel.accessibilityValue = value
    }

    private func addEdgeProbe(
        title: String,
        identifier: String,
        horizontal: NSLayoutXAxisAnchor,
        vertical: NSLayoutYAxisAnchor,
        trailing: Bool,
        bottom: Bool
    ) {
        let button = UIButton(type: .system)
        configureProbe(
            button,
            title: title,
            identifier: identifier
        )
        view.addSubview(button)

        let horizontalConstraint = trailing
            ? button.trailingAnchor.constraint(equalTo: horizontal, constant: -2)
            : button.leadingAnchor.constraint(equalTo: horizontal, constant: 2)
        let verticalConstraint = bottom
            ? button.bottomAnchor.constraint(equalTo: vertical, constant: -2)
            : button.topAnchor.constraint(equalTo: vertical, constant: 2)
        NSLayoutConstraint.activate([
            horizontalConstraint,
            verticalConstraint,
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    private func addScreenProbe(
        title: String,
        identifier: String,
        horizontal: NSLayoutXAxisAnchor,
        vertical: NSLayoutYAxisAnchor,
        trailing: Bool,
        bottom: Bool
    ) {
        addEdgeProbe(
            title: title,
            identifier: identifier,
            horizontal: horizontal,
            vertical: vertical,
            trailing: trailing,
            bottom: bottom
        )
    }

    private func configureProbe(
        _ button: UIButton,
        title: String,
        identifier: String
    ) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 9)
        button.backgroundColor =
            UIColor.systemBackground.withAlphaComponent(0.82)
        button.accessibilityIdentifier = identifier
        button.addTarget(
            self,
            action: #selector(edgeProbeTapped(_:)),
            for: .touchUpInside
        )
        button.translatesAutoresizingMaskIntoConstraints = false
    }
}

private final class FixtureHostingController<Content: View>:
    UIHostingController<Content> {}

private struct SwiftUIFixtureView: View {
    @State private var count = 0
    @State private var input = ""
    @State private var submitCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("SwiftUI Fixture")
                .font(.largeTitle)
                .accessibilityIdentifier("fixture.swiftui.heading")
            Text("SwiftUI Count \(count)")
                .accessibilityIdentifier("fixture.swiftui.count")
            Button("SwiftUI Increment") {
                count += 1
            }
            .accessibilityIdentifier("fixture.swiftui.increment")
            TextField("SwiftUI Input", text: $input)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("fixture.swiftui.input")
                .onSubmit {
                    submitCount += 1
                }
            Text("SwiftUI Value \(input)")
                .accessibilityIdentifier("fixture.swiftui.value")
            Text("SwiftUI Submit \(submitCount)")
                .accessibilityIdentifier("fixture.swiftui.submit")
        }
        .padding(28)
    }
}

final class WebFixtureViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.accessibilityIdentifier = "fixture.web.container"
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <style>
                body { font: 20px -apple-system; padding: 72px 24px; }
                button, input { display: block; font-size: 20px; margin: 24px 0; }
              </style>
              <h1>WKWebView Fixture</h1>
              <p id="state">Web Count 0</p>
              <button aria-label="Web Increment"
                onclick="window.fixtureCount=(window.fixtureCount||0)+1;
                         document.getElementById('state').textContent=
                         'Web Count '+window.fixtureCount">
                Web Increment
              </button>
              <p id="input-state">Web Value empty</p>
              <input aria-label="Web Input" placeholder="Web Input"
                oninput="document.getElementById('input-state').textContent=
                         'Web Value '+this.value">
            </html>
            """,
            baseURL: nil
        )
    }
}

final class MetalFixtureViewController: UIViewController, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var frameIndex = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = MTLCreateSystemDefaultDevice() else {
            let label = UILabel()
            label.text = "Metal unavailable"
            label.frame = view.bounds
            label.textAlignment = .center
            view.addSubview(label)
            return
        }

        let metalView = MTKView(frame: .zero, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 30
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        metalView.framebufferOnly = true
        metalView.isAccessibilityElement = false
        metalView.accessibilityElementsHidden = true
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        commandQueue = device.makeCommandQueue()

        let status = UILabel()
        status.text = "Metal opaque canvas active"
        status.textColor = .white
        status.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        status.accessibilityIdentifier = "fixture.metal.status"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        let overlay = UIButton(type: .system)
        overlay.setTitle("Metal Overlay", for: .normal)
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        overlay.accessibilityIdentifier = "fixture.metal.overlay"
        overlay.addTarget(
            self,
            action: #selector(metalOverlayTapped(_:)),
            for: .touchUpInside
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            status.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 28
            ),
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            overlay.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @objc private func metalOverlayTapped(_ sender: UIButton) {
        sender.setTitle("Metal Overlay Tapped", for: .normal)
        sender.accessibilityValue = "tapped"
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer()
        else {
            return
        }
        let phase = Double(frameIndex % 180) / 180.0
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.08 + phase * 0.12,
            green: 0.18,
            blue: 0.32 + phase * 0.18,
            alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor
        ) else {
            return
        }
        frameIndex += 1
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
