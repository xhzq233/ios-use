import Foundation
import IOSUseProtocol

extension DriverCommandResult {
    func machineOutput(for action: DriverAction) -> (data: MachineValue, warnings: [String]) {
        var value = baseMachineValue(for: action)
        if let postDom {
            value = merging(value, key: "postDom", value: machineDom(postDom))
        }
        let warnings = artifact?.warning.map { [$0] } ?? []
        return (value, warnings)
    }

    private func baseMachineValue(for action: DriverAction) -> MachineValue {
        switch (action, payload) {
        case (.dom, .dom(let dom)):
            return machineDom(dom)
        case (.waitFor(_, _, _, _, let gone, _), .waitFor(let wait)):
            return .object([
                "gone": .boolean(gone),
                "waited": .double(wait.waited),
                "element": gone ? .null : machineElement(wait.element),
            ])
        case (.screenshot, _):
            return artifact.map(machineArtifact) ?? .object([:])
        case (.tap, .element(let element)):
            return machineAction(element)
        case (.longPress, .element(let element)):
            return machineAction(element)
        case (
            .input(
                let tap,
                let content,
                let delete,
                let enter,
                _,
                _,
                _
            ),
            .element(let element)
        ):
            var value: [String: MachineValue] = [
                "tapTarget": tap.map(MachineValue.string) ?? .null,
                "contentLength": .integer(content.count),
                "deleteCount": .integer(delete),
                "enter": .boolean(enter),
            ]
            if case .object(let action) = machineAction(element) {
                value.merge(action) { _, new in new }
            }
            return .object(value)
        case (.swipe, .swipe(let swipe)):
            return .object([
                "element": machineElement(swipe.element),
                "hitView": swipe.hitView.map(machineHitView) ?? .null,
                "finalState": swipe.finalState.map(machineFinalState) ?? .null,
                "postcondition": swipe.postcondition.map(machinePostcondition) ?? .null,
                "scrolls": .integer(Int(swipe.scrolls)),
                "direction": .string(swipe.scrollDirection),
            ])
        case (.activateApp(let bundleId), _):
            return .object(["bundleId": .string(bundleId), "activated": .boolean(true)])
        case (.terminateApp(let bundleId), _):
            return .object(["bundleId": .string(bundleId), "terminated": .boolean(true)])
        case (.home, _):
            return .object(["pressed": .boolean(true)])
        case (.dismissAlert, .alert(let alert)):
            return machineAlert(alert)
        default:
            return .object([:])
        }
    }
}

func machineAlert(_ alert: ForyAlertPayload) -> MachineValue {
    .object([
        "dismissed": .boolean(alert.dismissed),
        "surface": alert.surface.isEmpty ? .null : .string(alert.surface),
        "kind": alert.kind.isEmpty ? .null : .string(alert.kind),
        "text": .string(alert.text),
        "buttonCount": .integer(Int(alert.buttonCount)),
        "buttons": .array(alert.buttons.map { button in
            .object([
                "queryIndex": .integer(Int(button.queryIndex)),
                "label": .string(button.label),
                "identifier": .string(button.identifier),
                "hittable": .boolean(button.hittable),
                "frame": button.frame.map(machineRect) ?? .null,
            ])
        }),
        "requestedSelection": .string(alert.requestedSelection),
        "selectionStrategy": alert.selectionStrategy.isEmpty
            ? .null
            : .string(alert.selectionStrategy),
        "selectedIndex": alert.selectedIndex >= 0
            ? .integer(Int(alert.selectedIndex))
            : .null,
        "button": alert.button.isEmpty ? .null : .string(alert.button),
        "layoutDirection": alert.layoutDirection.isEmpty
            ? .null
            : .string(alert.layoutDirection),
        "layoutDirectionSource": alert.layoutDirectionSource.isEmpty
            ? .null
            : .string(alert.layoutDirectionSource),
        "reason": alert.reason.isEmpty ? .null : .string(alert.reason),
    ])
}

func machineDriverErrorData(_ error: Error) -> MachineValue {
    guard let failure = driverFailureDetails(error) else {
        return .object([:])
    }
    let payload = failure.payload
    return .object([
        "target": payload.target.map(machineErrorTarget) ?? .null,
        "candidateCount": .integer(Int(payload.candidateCount)),
        "suggestions": .array(
            payload.suggestions.map(MachineValue.string)
        ),
        "candidates": .array(
            payload.candidates.map(machineErrorCandidate)
        ),
        "alert": payload.alert.map(machineAlert) ?? .null,
    ])
}

func renderDriverFailure(_ error: Error) -> String {
    guard let failure = driverFailureDetails(error) else {
        return String(describing: error)
    }
    return formatDriverError(
        message: failure.message,
        payload: failure.payload
    )
}

func driverMutationMayHaveApplied(_ payload: ForyErrorPayload) -> Bool {
    payload.category == IOSUseErrorCategory.action
        || payload.category == IOSUseErrorCategory.postcondition
}

private struct DriverFailureDetails {
    let message: String
    let payload: ForyErrorPayload
}

private func driverFailureDetails(
    _ error: Error
) -> DriverFailureDetails? {
    if case DriverClientError.driverError(
        let message,
        let payload
    ) = error {
        return DriverFailureDetails(message: message, payload: payload)
    }
    guard case DriverCommandExecutionError.postconditionFailed(
        let label,
        let underlying
    ) = error,
    case DriverClientError.driverError(
        let message,
        let underlyingPayload
    ) = underlying else {
        return nil
    }
    return DriverFailureDetails(
        message: "\(label) failed after mutation: \(message)",
        payload: ForyErrorPayload(
            category: IOSUseErrorCategory.postcondition,
            code: IOSUseErrorCode.postconditionFailed,
            phase: IOSUseErrorPhase.postcondition,
            retryable: underlyingPayload.retryable,
            fatal: underlyingPayload.fatal,
            target: underlyingPayload.target,
            candidateCount: underlyingPayload.candidateCount,
            suggestions: underlyingPayload.suggestions,
            candidates: underlyingPayload.candidates,
            alert: underlyingPayload.alert
        )
    )
}

private func machineErrorTarget(_ target: ForyTarget) -> MachineValue {
    .object([
        "label": .string(target.label),
        "point": target.point.map(machinePoint) ?? .null,
        "traits": target.traits.isEmpty
            ? .null
            : .string(target.traits),
        "cindex": target.cindex.map { .integer(Int($0)) } ?? .null,
    ])
}

private func machineErrorCandidate(
    _ candidate: ForyErrorCandidate
) -> MachineValue {
    let element = candidate.element
    return .object([
        "type": .string(
            IOSUseElementTypes.displayName(rawType: element.elemType)
        ),
        "typeCode": .integer(Int(element.elemType)),
        "label": .string(element.label),
        "value": .string(element.value),
        "traits": .array(element.traits.map(MachineValue.string)),
        "frame": element.rect.map(machineRect) ?? .null,
        "ancestors": .array(
            element.ancestors.map(MachineValue.string)
        ),
        "rejectedBy": .array(
            candidate.rejectedBy.map(MachineValue.string)
        ),
    ])
}

func machineDom(_ payload: ForyDomPayload) -> MachineValue {
    .object([
        "app": .string(payload.app),
        "windowSize": machinePoint(payload.windowSize),
        "raw": payload.raw.isEmpty ? .null : .string(payload.raw),
        "snapshotGeneration": .integer(Int(payload.snapshotGeneration)),
        "elements": .array(DriverOutput.presentationDomElements(payload.elements).map(machineDomElement)),
    ])
}

private func machineDomElement(_ element: ForyDomElement) -> MachineValue {
    .object([
        "traits": .array(element.traits.map(MachineValue.string)),
        "nodeID": .string(element.nodeID),
        "semanticType": .string(element.type),
        "elementType": .integer(Int(element.elementType)),
        "childCount": .integer(Int(element.childCount)),
        "label": .string(element.label),
        "value": .string(element.value),
        "identifier": .string(element.identifier),
        "hint": .string(element.hint),
        "class": .string(element.className),
        "state": machineState(element.state),
        "hierarchy": machineHierarchy(element.hierarchy),
        "ancestors": .array(element.ancestors.map(MachineValue.string)),
        "zOrder": .integer(Int(element.zOrder)),
        "snapshotGeneration": .integer(Int(element.snapshotGeneration)),
        "frame": element.rect.map(machineRect) ?? .null,
    ])
}

private func machineElement(_ element: ForyElementSummary) -> MachineValue {
    .object([
        "type": .string(DriverOutput.elementTypeName(element.elemType)),
        "typeCode": .integer(Int(element.elemType)),
        "nodeID": .string(element.nodeID),
        "semanticType": .string(element.type),
        "label": .string(element.label),
        "value": .string(element.value),
        "identifier": .string(element.identifier),
        "hint": .string(element.hint),
        "class": .string(element.className),
        "traits": .array(element.traits.map(MachineValue.string)),
        "state": machineState(element.state),
        "frame": element.rect.map(machineRect) ?? .null,
        "hierarchy": machineHierarchy(element.hierarchy),
        "ancestors": .array(element.ancestors.map(MachineValue.string)),
        "zOrder": .integer(Int(element.zOrder)),
        "snapshotGeneration": .integer(Int(element.snapshotGeneration)),
    ])
}

private func machineAction(
    _ payload: ForyElementPayload
) -> MachineValue {
    .object([
        "element": machineElement(payload.element),
        "hitView": payload.hitView.map(machineHitView) ?? .null,
        "finalState": payload.finalState.map(machineFinalState) ?? .null,
        "postcondition": payload.postcondition.map(machinePostcondition) ?? .null,
    ])
}

private func machineHitView(_ hitView: ForyHitView) -> MachineValue {
    .object([
        "class": .string(hitView.className),
        "frame": hitView.rect.map(machineRect) ?? .null,
        "accessibilityIdentifier":
            .string(hitView.accessibilityIdentifier),
        "label": .string(hitView.label),
    ])
}

private func machineFinalState(
    _ state: ForyTouchFinalState
) -> MachineValue {
    .object([
        "point": machinePoint(state.point),
        "touchID": .integer(Int(state.touchID)),
        "phase": .string(state.phase),
        "firstResponderClass":
            state.firstResponderClass.isEmpty
                ? .null
                : .string(state.firstResponderClass),
    ])
}

private func machinePostcondition(
    _ postcondition: ForyActionPostcondition
) -> MachineValue {
    .object([
        "snapshotGeneration":
            .integer(Int(postcondition.snapshotGeneration)),
        "element": postcondition.element.map(machineElement) ?? .null,
        "changed": .boolean(postcondition.changed),
        "domChanged": .boolean(postcondition.domChanged),
        "pixelEvidence": postcondition.pixelEvidence.map {
            .object([
                "beforeHash": .string($0.beforeHash),
                "afterHash": .string($0.afterHash),
                "beforeCaptureGeneration":
                    .integer(Int($0.beforeCaptureGeneration)),
                "afterCaptureGeneration":
                    .integer(Int($0.afterCaptureGeneration)),
                "logicalRect": .object([
                    "x": .double($0.logicalX),
                    "y": .double($0.logicalY),
                    "width": .double($0.logicalWidth),
                    "height": .double($0.logicalHeight),
                ]),
                "changed": .boolean($0.changed),
            ])
        } ?? .null,
    ])
}

private func machineState(
    _ state: ForyElementState
) -> MachineValue {
    .object([
        "enabled": .boolean(state.enabled),
        "visible": .boolean(state.visible),
        "selected": .boolean(state.selected),
        "focused": .boolean(state.focused),
        "opaque": .boolean(state.opaque),
    ])
}

private func machineHierarchy(
    _ hierarchy: ForyElementHierarchy
) -> MachineValue {
    .object([
        "parentID":
            hierarchy.parentID.isEmpty
                ? .null
                : .string(hierarchy.parentID),
        "depth": .integer(Int(hierarchy.depth)),
        "index": .integer(Int(hierarchy.index)),
        "path": .array(
            hierarchy.path.map(MachineValue.string)
        ),
    ])
}

private func machineArtifact(_ artifact: ScreenshotArtifactService.Result) -> MachineValue {
    var value: [String: MachineValue] = [
        "imagePath": .string(artifact.imagePath),
        "ocrPath": artifact.ocrSidecarPath.map(MachineValue.string) ?? .null,
        "pixelSize": artifact.pixelSize.map(machinePoint) ?? .null,
        "logicalSize": artifact.logicalSize.map(machinePoint) ?? .null,
        "scale": artifact.scale.map(MachineValue.double) ?? .null,
        "geometrySource": artifact.geometrySource.map(MachineValue.string) ?? .null,
        "snapshotGeneration": artifact.snapshotGeneration.map {
            .integer(Int($0))
        } ?? .null,
        "captureGeneration": artifact.captureGeneration.map {
            .integer(Int($0))
        } ?? .null,
        "runtimeEvidence": artifact.runtimeEvidence.map {
            .object(
                $0.mapValues(
                    StatusService.playCoverRuntimeJSONMachineValue
                )
            )
        } ?? .null,
    ]
    if let performance = artifact.performance {
        value["performance"] = .object([
            "screenshotElapsedMs": .integer(performance.screenshotElapsedMs),
            "displayInfoElapsedMs": performance.displayInfoElapsedMs.map(MachineValue.integer) ?? .null,
            "displayInfoServiceElapsedMs": performance.displayInfoServiceElapsedMs.map(MachineValue.integer) ?? .null,
            "totalElapsedMs": .integer(performance.totalElapsedMs),
        ])
    }
    return .object(value)
}

private func machinePoint(_ point: ForyPoint) -> MachineValue {
    .array([.double(point.x), .double(point.y)])
}

private func machineRect(_ rect: ForyRect) -> MachineValue {
    .array([
        .integer(Int(rect.x)),
        .integer(Int(rect.y)),
        .integer(Int(rect.w)),
        .integer(Int(rect.h)),
    ])
}

private func merging(_ base: MachineValue, key: String, value: MachineValue) -> MachineValue {
    guard case .object(var object) = base else {
        return .object(["result": base, key: value])
    }
    object[key] = value
    return .object(object)
}
