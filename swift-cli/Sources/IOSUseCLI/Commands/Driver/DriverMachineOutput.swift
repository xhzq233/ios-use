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
        case (.dom, .dom(let dom)), (.inspect, .dom(let dom)):
            var value = machineDom(dom)
            if let artifact {
                value = merging(value, key: "visualEvidence", value: machineArtifact(artifact))
            }
            return value
        case (.waitFor(_, _, _, _, let gone, _), .waitFor(let wait)):
            return .object([
                "gone": .boolean(gone),
                "waited": .double(wait.waited),
                "element": gone ? .null : machineElement(wait.element),
            ])
        case (.screenshot, _):
            return artifact.map(machineArtifact) ?? .object([:])
        case (.tap, .element(let element)):
            return .object(["element": machineElement(element.element)])
        case (.longPress, .element(let element)):
            return .object(["element": machineElement(element.element)])
        case (.input(let tap, let content, let delete, let enter, _, _, _), _):
            return .object([
                "tapTarget": tap.map(MachineValue.string) ?? .null,
                "contentLength": .integer(content.count),
                "deleteCount": .integer(delete),
                "enter": .boolean(enter),
            ])
        case (.swipe, .swipe(let swipe)):
            return .object([
                "element": machineElement(swipe.element),
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
            return .object([
                "dismissed": .boolean(alert.dismissed),
                "text": .string(alert.text),
                "button": .string(alert.button),
                "reason": .string(alert.reason),
            ])
        default:
            return .object([:])
        }
    }
}

func machineDom(_ payload: ForyDomPayload) -> MachineValue {
    .object([
        "app": .string(payload.app),
        "windowSize": machinePoint(payload.windowSize),
        "raw": payload.raw.isEmpty ? .null : .string(payload.raw),
        "elements": .array(DriverOutput.presentationDomElements(payload.elements).map(machineDomElement)),
    ])
}

private func machineDomElement(_ element: ForyDomElement) -> MachineValue {
    .object([
        "traits": .array(element.traits.map(MachineValue.string)),
        "childCount": .integer(Int(element.childCount)),
        "label": .string(element.label),
        "value": .string(element.value),
        "frame": element.rect.map(machineRect) ?? .null,
    ])
}

private func machineElement(_ element: ForyElementSummary) -> MachineValue {
    .object([
        "type": .string(DriverOutput.elementTypeName(element.elemType)),
        "typeCode": .integer(Int(element.elemType)),
        "label": .string(element.label),
        "frame": element.rect.map(machineRect) ?? .null,
        "ancestors": .array(element.ancestors.map(MachineValue.string)),
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
