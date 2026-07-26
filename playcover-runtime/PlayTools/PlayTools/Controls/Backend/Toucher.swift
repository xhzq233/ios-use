//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

final class Toucher {
    static weak var keyWindow: UIWindow?
    static weak var keyView: UIView?
    // For debug only
    static var logEnabled = false
    static var logFilePath =
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/toucher.log"
    static private var logCount = 0
    static var logFile: FileHandle?
    /**
     on invocations with phase "began", an int id is allocated, which can be used later to refer to this touch point.
     on invocations with phase "ended", id is set to nil representing the touch point is no longer valid.
     */
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?,
                         preferredWindow: UIWindow? = nil,
                         preferredView: UIView? = nil,
                         // Name info for debug use
                         actionName: String, keyName: String) {
        if phase == UITouch.Phase.began {
            if tid != nil {
                return
            }
            tid = -1
            keyWindow = preferredWindow ?? screen.keyWindow
            keyView = preferredView ?? keyWindow?.hitTest(point, with: nil)
        } else if tid == nil {
            return
        }
        guard let activeWindow = keyWindow, let activeView = keyView,
              let activeID = tid else {
            tid = nil
            return
        }
        tid = PTFakeMetaTouch.fakeTouchId(
            activeID,
            at: point,
            with: phase,
            in: activeWindow,
            on: activeView
        )
        let resultingID = tid ?? -1
        writeLog(logMessage:
                "\(phase.rawValue.description) \(resultingID.description) \(point.debugDescription)")
        if resultingID < 0 {
            tid = nil
        }
        // ios-use intentionally removes PlayTools' DebugModel overlay. The
        // action/key names remain part of the vendored API for provenance.
        _ = actionName
        _ = keyName
    }

    static func setupLogfile() {
        if FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil) {
            logFile = FileHandle(forWritingAtPath: logFilePath)
        } else {
            return
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { _ in
            try? logFile?.close()
        }
    }

    static func writeLog(logMessage: String) {
        if !logEnabled {
            return
        }
        guard let file = logFile else {
            setupLogfile()
            return
        }
        let message = "\(DispatchTime.now().rawValue) \(logMessage)\n"
        guard let data = message.data(using: .utf8) else {
            return
        }
        logCount += 1
        // roll over
        if logCount > 60000 {
            file.seek(toFileOffset: 0)
            logCount = 0
        }
        file.write(data)
    }
}
