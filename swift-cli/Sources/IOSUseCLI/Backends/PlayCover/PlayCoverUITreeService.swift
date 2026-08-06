import Foundation
import IOSUseProtocol

enum PlayCoverUITreeService {
    enum Error:
        Swift.Error,
        Equatable,
        CustomStringConvertible,
        MachineErrorConvertible,
        Sendable
    {
        case requiresMacSession

        var description: String {
            "`ios-use ui-tree` requires an active Mac session; "
                + "run `ios-use stop`, then `ios-use start --mac ...`"
        }

        var machineError: MachineError {
            MachineError(
                message: description,
                category: IOSUseErrorCategory.session,
                code: "mac_session_required",
                phase: IOSUseErrorPhase.session,
                retryable: true,
                fatal: false,
                mutationMayHaveApplied: false
            )
        }
    }

    static func run(
        options: UITreeOptions,
        paths: IOSUsePaths
    ) throws -> PlayCoverRuntimeUITreePayload {
        let session = try SessionService.requireDriverLock(paths: paths)
        guard session.deviceType == PlayCoverSessionService.deviceType else {
            throw Error.requiresMacSession
        }
        let refreshAlertStatus =
            CLIInvocationContext.current?.claimAlertRefresh() ?? true
        let client = try PlayCoverDriverClient.runtimeClient(
            for: session,
            timeoutSeconds: PlayCoverRuntimeClient.defaultTimeoutSeconds,
            refreshAlertStatus: refreshAlertStatus
        )
        return try client.uiTree(
            PlayCoverRuntimeUITreeArguments(
                target: options.target,
                depth: options.depth
            )
        )
    }

    static func format(_ payload: PlayCoverRuntimeUITreePayload) -> String {
        var lines = [
            "UIKit view tree · \(payload.nodeCount) nodes · depth limit \(payload.maxDepth)",
        ]
        if let target = payload.target {
            lines.append("Target: \(target)")
        }
        for (index, root) in payload.roots.enumerated() {
            append(
                root,
                prefix: "",
                isLast: index == payload.roots.count - 1,
                parentViewControllerClass: nil,
                to: &lines
            )
        }
        if payload.truncated {
            lines.append("… output truncated by the depth or node limit")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func machineData(
        _ payload: PlayCoverRuntimeUITreePayload
    ) -> MachineValue {
        .object([
            "target": payload.target.map(MachineValue.string) ?? .null,
            "maxDepth": .integer(payload.maxDepth),
            "nodeCount": .integer(payload.nodeCount),
            "truncated": .boolean(payload.truncated),
            "roots": .array(payload.roots.map(machineNode)),
        ])
    }

    private static func append(
        _ node: PlayCoverRuntimeUITreeNode,
        prefix: String,
        isLast: Bool,
        parentViewControllerClass: String?,
        to lines: inout [String]
    ) {
        let branch = isLast ? "└─ " : "├─ "
        let frame = node.frame
        var summary = "\(prefix)\(branch)\(node.class)"
        summary += String(
            format: " frame=(%.1f,%.1f %.1fx%.1f)",
            frame.x,
            frame.y,
            frame.width,
            frame.height
        )
        if let viewControllerClass = node.viewControllerClass,
           viewControllerClass != parentViewControllerClass {
            summary += " vc=\(viewControllerClass)"
        }
        if node.hidden {
            summary += " hidden"
        }
        if node.alpha < 0.999 {
            summary += String(format: " alpha=%.3f", node.alpha)
        }
        if !node.userInteractionEnabled {
            summary += " interaction=off"
        }
        if node.properties["image"] != nil,
           node.contentMode != "scaleToFill" {
            summary += " contentMode=\(node.contentMode)"
        }
        if node.clipsToBounds {
            summary += " clips"
        }
        if let label = node.accessibilityLabel, !label.isEmpty {
            summary += " label=\(quoted(label))"
        }
        if let identifier = node.accessibilityIdentifier,
           !identifier.isEmpty {
            summary += " identifier=\(quoted(identifier))"
        }
        let propertyText: [String] = node.properties.keys.sorted().map { key in
            let value = node.properties[key]!
            return "\(key)=\(display(value))"
        }
        if !propertyText.isEmpty {
            summary += " {\(propertyText.joined(separator: ", "))}"
        }
        lines.append(summary)

        let childPrefix = prefix + (isLast ? "   " : "│  ")
        let currentViewControllerClass =
            node.viewControllerClass ?? parentViewControllerClass
        for (index, child) in node.subviews.enumerated() {
            append(
                child,
                prefix: childPrefix,
                isLast: index == node.subviews.count - 1,
                parentViewControllerClass: currentViewControllerClass,
                to: &lines
            )
        }
    }

    private static func machineNode(
        _ node: PlayCoverRuntimeUITreeNode
    ) -> MachineValue {
        .object([
            "childCount": .integer(node.childCount),
            "class": .string(node.class),
            "viewControllerClass": node.viewControllerClass
                .map(MachineValue.string) ?? .null,
            "frame": machineFrame(node.frame),
            "bounds": machineFrame(node.bounds),
            "hidden": .boolean(node.hidden),
            "alpha": .double(node.alpha),
            "userInteractionEnabled": .boolean(
                node.userInteractionEnabled
            ),
            "clipsToBounds": .boolean(node.clipsToBounds),
            "contentMode": .string(node.contentMode),
            "accessibilityIdentifier": node.accessibilityIdentifier
                .map(MachineValue.string) ?? .null,
            "accessibilityLabel": node.accessibilityLabel
                .map(MachineValue.string) ?? .null,
            "layout": .object([
                "ambiguous": .boolean(node.layout.ambiguous),
                "translatesAutoresizingMaskIntoConstraints": .boolean(
                    node.layout.translatesAutoresizingMaskIntoConstraints
                ),
                "constraintCount": .integer(node.layout.constraintCount),
            ]),
            "properties": .object(
                node.properties.mapValues(
                    StatusService.playCoverRuntimeJSONMachineValue
                )
            ),
            "subviews": .array(node.subviews.map(machineNode)),
        ])
    }

    private static func machineFrame(
        _ frame: PlayCoverRuntimeFrame
    ) -> MachineValue {
        .object([
            "x": .double(frame.x),
            "y": .double(frame.y),
            "width": .double(frame.width),
            "height": .double(frame.height),
        ])
    }

    private static func display(
        _ value: PlayCoverRuntimeJSONValue
    ) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value
                ? String(Int(value))
                : String(format: "%.3f", value)
        case .string(let value):
            return quoted(value)
        case .array(let values):
            return "[" + values.map(display).joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().compactMap { key in
                values[key].map { "\(key):\(display($0))" }
            }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\(value)\""
    }
}
