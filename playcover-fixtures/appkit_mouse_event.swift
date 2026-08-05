import AppKit
import CoreGraphics
import Foundation

enum ProbeFailure: Error, CustomStringConvertible {
    case usage
    case invalid(String)
    case permission
    case eventCreation
    case cursorWarp(CGError)
    case cursorPosition(CGPoint)
    case targetApplication(Int32)
    case targetWindowAtPoint(Int32, CGPoint)
    case targetWindowNumber(expected: UInt32, actual: UInt32)
    case lockedSession
    case screenEnumeration(CGError)

    var description: String {
        switch self {
        case .usage:
            return """
                usage: appkit_mouse_event.swift --screens | \
                <global-x> <global-y> <token> <target-pid> \
                [expected-window-number] | \
                --drag <start-x> <start-y> <end-x> <end-y> \
                <token> <target-pid> [expected-window-number]
                """
        case .invalid(let field):
            return "invalid \(field)"
        case .permission:
            return "PostEvent access is not granted to the ios-use live gate"
        case .eventCreation:
            return "CoreGraphics could not create the mouse events"
        case .cursorWarp(let error):
            return "CoreGraphics cursor warp failed: \(error.rawValue)"
        case .cursorPosition(let point):
            return "CoreGraphics cursor did not reach the requested point: \(point)"
        case .targetApplication(let pid):
            return "no running target application exists for PID \(pid)"
        case .targetWindowAtPoint(let pid, let point):
            return "frontmost layer-zero window at \(point) does not belong to target PID \(pid)"
        case .targetWindowNumber(let expected, let actual):
            return "frontmost target window number \(actual) does not match expected window number \(expected)"
        case .lockedSession:
            return "the macOS console session is locked; global AppKit mouse delivery cannot be verified"
        case .screenEnumeration(let error):
            return "CoreGraphics could not enumerate online displays: \(error.rawValue)"
        }
    }
}

private let maximumSafeJSONInteger: Int64 = 9_007_199_254_740_991

private func rectJSON(_ rect: CGRect) -> [String: Double] {
    [
        "x": rect.origin.x,
        "y": rect.origin.y,
        "width": rect.size.width,
        "height": rect.size.height,
    ]
}

private func pointJSON(_ point: CGPoint) -> [String: Double] {
    ["x": point.x, "y": point.y]
}

private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    guard
        let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber,
        number.uint64Value > 0,
        number.uint64Value <= UInt64(UInt32.max)
    else {
        return nil
    }
    return CGDirectDisplayID(number.uint32Value)
}

private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
    // A macOS display topology is bounded far below this fixed capacity. The
    // fixed array avoids a racy count-then-fetch pair while displays change.
    let capacity: UInt32 = 128
    var displayIDs = Array(
        repeating: kCGNullDirectDisplay,
        count: Int(capacity)
    )
    var count: UInt32 = 0
    let result = CGGetOnlineDisplayList(
        capacity,
        &displayIDs,
        &count
    )
    guard result == .success else {
        throw ProbeFailure.screenEnumeration(result)
    }
    return Array(displayIDs.prefix(Int(count)))
}

private func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
    guard
        let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
    else {
        return nil
    }
    let uuid = unmanagedUUID.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String?
}

private func screenTopology() throws -> [[String: Any]] {
    var appKitScreensByID: [CGDirectDisplayID: NSScreen] = [:]
    for screen in NSScreen.screens {
        if
            let displayID = screenDisplayID(screen),
            appKitScreensByID[displayID] == nil
        {
            appKitScreensByID[displayID] = screen
        }
    }
    let discoveredIDs = Set(try onlineDisplayIDs())
        .union(appKitScreensByID.keys)
        .sorted()
    return discoveredIDs.map { displayID in
        let screen = appKitScreensByID[displayID]
        return [
            "screenDisplayID": displayID,
            "displayUUID": displayUUID(displayID) ?? NSNull(),
            "screenIsMain": CGDisplayIsMain(displayID) != 0,
            "hasNSScreen": screen != nil,
            "frame": screen.map { rectJSON($0.frame) } ?? NSNull(),
            "visibleFrame":
                screen.map { rectJSON($0.visibleFrame) } ?? NSNull(),
            "cgBounds": rectJSON(CGDisplayBounds(displayID)),
            "backingScaleFactor":
                screen.map(\.backingScaleFactor) ?? NSNull(),
            "active": CGDisplayIsActive(displayID) != 0,
            "online": CGDisplayIsOnline(displayID) != 0,
            "mirrored": CGDisplayIsInMirrorSet(displayID) != 0,
            "builtin": CGDisplayIsBuiltin(displayID) != 0,
        ]
    }
}

private func writeJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func displayID(
    containing point: CGPoint,
    topology: [[String: Any]]
) -> UInt32? {
    for row in topology {
        guard
            let rawID = row["screenDisplayID"] as? NSNumber,
            let rawBounds = row["cgBounds"] as? [String: Double],
            let x = rawBounds["x"],
            let y = rawBounds["y"],
            let width = rawBounds["width"],
            let height = rawBounds["height"],
            CGRect(x: x, y: y, width: width, height: height)
                .contains(point)
        else {
            continue
        }
        return rawID.uint32Value
    }
    return nil
}

private func targetWindowNumber(
    targetPID: Int32,
    point: CGPoint
) throws -> UInt32 {
    guard
        let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]]
    else {
        throw ProbeFailure.targetWindowAtPoint(targetPID, point)
    }
    for row in rawWindows {
        guard
            (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let rawBounds = row[kCGWindowBounds as String]
                as? NSDictionary,
            let bounds = CGRect(
                dictionaryRepresentation: rawBounds as CFDictionary
            ),
            bounds.contains(point)
        else {
            continue
        }
        guard
            (row[kCGWindowOwnerPID as String] as? NSNumber)?
                .int32Value == targetPID,
            let windowNumber =
                (row[kCGWindowNumber as String] as? NSNumber)?
                    .uint32Value
        else {
            break
        }
        return windowNumber
    }
    throw ProbeFailure.targetWindowAtPoint(targetPID, point)
}

do {
    let arguments = CommandLine.arguments
    if arguments.count == 2 && arguments[1] == "--screens" {
        let screens = try screenTopology()
        try writeJSON([
            "operation": "screens",
            "mainDisplayID": CGMainDisplayID(),
            "screenCount": screens.count,
            "screens": screens,
            "postEventAccessRequired": false,
            "lockedSessionAllowed": true,
        ])
        exit(0)
    }

    let isDrag = arguments.count >= 2 && arguments[1] == "--drag"
    let validArgumentCount = isDrag
        ? (arguments.count == 8 || arguments.count == 9)
        : (arguments.count == 5 || arguments.count == 6)
    guard validArgumentCount else {
        throw ProbeFailure.usage
    }
    guard
        let startX = Double(arguments[isDrag ? 2 : 1]),
        startX.isFinite
    else {
        throw ProbeFailure.invalid("start-x")
    }
    guard
        let startY = Double(arguments[isDrag ? 3 : 2]),
        startY.isFinite
    else {
        throw ProbeFailure.invalid("start-y")
    }
    let endX: Double
    let endY: Double
    if isDrag {
        guard
            let parsedEndX = Double(arguments[4]),
            parsedEndX.isFinite,
            let parsedEndY = Double(arguments[5]),
            parsedEndY.isFinite
        else {
            throw ProbeFailure.invalid("drag-end")
        }
        endX = parsedEndX
        endY = parsedEndY
    } else {
        endX = startX
        endY = startY
    }
    guard
        let token = Int64(arguments[isDrag ? 6 : 3]),
        token > 0,
        token <= maximumSafeJSONInteger
    else {
        throw ProbeFailure.invalid("token")
    }
    guard
        let targetPID = Int32(arguments[isDrag ? 7 : 4]),
        targetPID > 0
    else {
        throw ProbeFailure.invalid("target-pid")
    }
    let expectedWindowNumberIndex = isDrag ? 8 : 5
    let expectedWindowNumber: UInt32?
    if arguments.count > expectedWindowNumberIndex {
        guard
            let parsed = UInt64(arguments[expectedWindowNumberIndex]),
            parsed > 0,
            parsed <= UInt64(UInt32.max)
        else {
            throw ProbeFailure.invalid("expected-window-number")
        }
        expectedWindowNumber = UInt32(parsed)
    } else {
        expectedWindowNumber = nil
    }

    guard CGPreflightPostEventAccess() else {
        throw ProbeFailure.permission
    }
    if
        let session = CGSessionCopyCurrentDictionary()
            as? [String: Any],
        (session["CGSSessionScreenIsLocked"] as? NSNumber)?
            .boolValue == true
    {
        throw ProbeFailure.lockedSession
    }
    guard
        let targetApplication = NSRunningApplication(
            processIdentifier: targetPID
        ),
        !targetApplication.isTerminated
    else {
        throw ProbeFailure.targetApplication(targetPID)
    }
    let targetWasActive = targetApplication.isActive
    let activationRequested = targetWasActive
        ? false
        : targetApplication.activate(options: [.activateAllWindows])
    if activationRequested {
        Thread.sleep(forTimeInterval: 0.05)
    }
    let startPoint = CGPoint(x: startX, y: startY)
    let endPoint = CGPoint(x: endX, y: endY)
    let resolvedWindowNumber = try targetWindowNumber(
        targetPID: targetPID,
        point: startPoint
    )
    if
        let expectedWindowNumber,
        expectedWindowNumber != resolvedWindowNumber
    {
        throw ProbeFailure.targetWindowNumber(
            expected: expectedWindowNumber,
            actual: resolvedWindowNumber
        )
    }
    guard
        let source = CGEventSource(stateID: .hidSystemState),
        let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: startPoint,
            mouseButton: .left
        ),
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: startPoint,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: endPoint,
            mouseButton: .left
        )
    else {
        throw ProbeFailure.eventCreation
    }
    let warpResult = CGWarpMouseCursorPosition(startPoint)
    guard warpResult == .success else {
        throw ProbeFailure.cursorWarp(warpResult)
    }
    Thread.sleep(forTimeInterval: 0.05)
    guard
        let cursorEvent = CGEvent(source: nil),
        abs(cursorEvent.location.x - startPoint.x) <= 0.5,
        abs(cursorEvent.location.y - startPoint.y) <= 0.5
    else {
        throw ProbeFailure.cursorPosition(
            CGEvent(source: nil)?.location ?? .zero
        )
    }
    moved.setIntegerValueField(.eventSourceUserData, value: token)
    moved.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    for event in [down, up] {
        event.setIntegerValueField(.eventSourceUserData, value: token)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
    }
    down.setDoubleValueField(.mouseEventPressure, value: 1)
    up.setDoubleValueField(.mouseEventPressure, value: 0)
    down.post(tap: .cghidEventTap)

    var interpolationEventCount = 0
    if isDrag {
        let distance = hypot(endX - startX, endY - startY)
        let stepCount = max(
            2,
            min(240, Int(ceil(distance / 16.0)))
        )
        for step in 1...stepCount {
            let fraction = Double(step) / Double(stepCount)
            let point = CGPoint(
                x: startX + (endX - startX) * fraction,
                y: startY + (endY - startY) * fraction
            )
            guard let dragged = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw ProbeFailure.eventCreation
            }
            dragged.setIntegerValueField(
                .eventSourceUserData,
                value: token
            )
            dragged.setIntegerValueField(.mouseEventClickState, value: 1)
            dragged.setDoubleValueField(.mouseEventPressure, value: 1)
            dragged.post(tap: .cghidEventTap)
            interpolationEventCount += 1
            Thread.sleep(forTimeInterval: 0.008)
        }
        Thread.sleep(forTimeInterval: 0.03)
    } else {
        Thread.sleep(forTimeInterval: 0.02)
    }
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)

    let finalCursorPoint = CGEvent(source: nil)?.location ?? .zero
    let endPointReached =
        abs(finalCursorPoint.x - endPoint.x) <= 1 &&
        abs(finalCursorPoint.y - endPoint.y) <= 1
    let topology = try screenTopology()
    let startDisplayID = displayID(
        containing: startPoint,
        topology: topology
    )
    let endDisplayID = displayID(
        containing: endPoint,
        topology: topology
    )
    let crossDisplayDrag = isDrag &&
        startDisplayID != nil &&
        endDisplayID != nil &&
        startDisplayID != endDisplayID
    let windowNumberMatched =
        expectedWindowNumber == nil ||
        expectedWindowNumber == resolvedWindowNumber

    try writeJSON([
        "operation": isDrag ? "drag" : "click",
        "token": token,
        "sourcePID": ProcessInfo.processInfo.processIdentifier,
        "targetPID": targetPID,
        "targetWindowNumber": resolvedWindowNumber,
        "expectedWindowNumber": expectedWindowNumber.map {
            NSNumber(value: $0)
        } ?? NSNull(),
        "windowNumberMatched": windowNumberMatched,
        "targetWasActive": targetWasActive,
        "activationRequested": activationRequested,
        "targetActiveBeforePost": targetApplication.isActive,
        "globalPoint": pointJSON(endPoint),
        "startPoint": pointJSON(startPoint),
        "endPoint": pointJSON(endPoint),
        "finalCursorPoint": pointJSON(finalCursorPoint),
        "endPointReached": endPointReached,
        "interpolationEventCount": interpolationEventCount,
        "startDisplayID": startDisplayID.map {
            NSNumber(value: $0)
        } ?? NSNull(),
        "endDisplayID": endDisplayID.map {
            NSNumber(value: $0)
        } ?? NSNull(),
        "crossDisplayDrag": crossDisplayDrag,
        "postEventAccess": true,
    ])
} catch {
    FileHandle.standardError.write(
        Data("\(error)\n".utf8)
    )
    exit(1)
}
