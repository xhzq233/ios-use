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
    case lockedSession

    var description: String {
        switch self {
        case .usage:
            return "usage: appkit_mouse_event.swift <global-x> <global-y> <token> <target-pid> | --drag <start-x> <start-y> <end-x> <end-y> <token> <target-pid>"
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
        case .lockedSession:
            return "the macOS console session is locked; global AppKit mouse delivery cannot be verified"
        }
    }
}

do {
    let arguments = CommandLine.arguments
    let isDrag = arguments.count == 8 && arguments[1] == "--drag"
    guard arguments.count == 5 || isDrag else {
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
        token <= 9_007_199_254_740_991
    else {
        throw ProbeFailure.invalid("token")
    }
    guard
        let targetPID = Int32(arguments[isDrag ? 7 : 4]),
        targetPID > 0
    else {
        throw ProbeFailure.invalid("target-pid")
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
    let activationRequested = targetApplication.activate(
        options: [.activateAllWindows]
    )
    Thread.sleep(forTimeInterval: 0.05)
    let startPoint = CGPoint(x: startX, y: startY)
    let endPoint = CGPoint(x: endX, y: endY)
    guard
        let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]]
    else {
        throw ProbeFailure.targetWindowAtPoint(targetPID, startPoint)
    }
    var targetWindowNumber: UInt32?
    for row in rawWindows {
        guard
            (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == targetPID,
            let rawBounds = row[kCGWindowBounds as String]
                as? NSDictionary,
            let windowNumber =
                (row[kCGWindowNumber as String] as? NSNumber)?
                    .uint32Value
        else {
            if
                (row[kCGWindowLayer as String] as? NSNumber)?
                    .intValue == 0,
                let rawBounds = row[kCGWindowBounds as String]
                    as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: rawBounds as CFDictionary
                ),
                bounds.contains(startPoint)
            {
                break
            }
            continue
        }
        guard
            let bounds = CGRect(
                dictionaryRepresentation: rawBounds as CFDictionary
            ),
            bounds.contains(startPoint)
        else {
            continue
        }
        targetWindowNumber = windowNumber
        break
    }
    guard let targetWindowNumber else {
        throw ProbeFailure.targetWindowAtPoint(targetPID, startPoint)
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
    if isDrag {
        Thread.sleep(forTimeInterval: 0.03)
        guard let dragged = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: endPoint,
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
        Thread.sleep(forTimeInterval: 0.06)
    } else {
        Thread.sleep(forTimeInterval: 0.02)
    }
    up.post(tap: .cghidEventTap)

    let output: [String: Any] = [
        "operation": isDrag ? "drag" : "click",
        "token": token,
        "sourcePID": ProcessInfo.processInfo.processIdentifier,
        "targetPID": targetPID,
        "targetWindowNumber": targetWindowNumber,
        "activationRequested": activationRequested,
        "targetActiveBeforePost": targetApplication.isActive,
        "globalPoint": ["x": endX, "y": endY],
        "startPoint": ["x": startX, "y": startY],
        "endPoint": ["x": endX, "y": endY],
        "postEventAccess": true,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: output,
        options: [.sortedKeys]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
} catch {
    FileHandle.standardError.write(
        Data("\(error)\n".utf8)
    )
    exit(1)
}
