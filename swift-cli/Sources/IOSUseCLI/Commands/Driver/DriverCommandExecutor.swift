import Foundation
import IOSUseProtocol

enum DriverCommandPayload {
    case dom(ForyDomPayload)
    case waitFor(ForyWaitForPayload)
    case screenshot(Data)
    case element(ForyElementPayload)
    case swipe(ForySwipePayload)
    case alert(ForyAlertPayload)
}

struct DriverCommandResult {
    var stdout: String
    var payload: DriverCommandPayload?
}

enum DriverCommandExecutor {
    typealias ClientRunner = ((DriverCommandClient) throws -> DriverCommandPayload?) throws -> DriverCommandPayload?

    static func execute(action: DriverAction, paths: IOSUsePaths, hostDeviceTypeHint: String? = nil, clientRunner: ClientRunner) throws -> DriverCommandResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        var ok = false
        defer {
            appendActionLog(
                action: action.name,
                ok: ok,
                elapsedMs: Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond),
                paths: paths
            )
        }
        switch action {
        case .dom(let raw, let fresh, let waitQuiescence):
            let payload = try requiredPayload(clientRunner { .dom(try $0.dom(raw: raw, fresh: fresh, waitQuiescence: waitQuiescence)) }, as: ForyDomPayload.self)
            ok = true
            return DriverCommandResult(stdout: DriverOutput.formatDom(payload), payload: .dom(payload))

        case .waitFor(let label, let timeout, let traits, let cindex, let gone):
            let payload = try requiredPayload(clientRunner { .waitFor(try $0.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex, gone: gone)) }, as: ForyWaitForPayload.self)
            ok = true
            return DriverCommandResult(stdout: DriverOutput.formatWaitFor(label: label, payload: payload, gone: gone), payload: .waitFor(payload))

        case .screenshot(let name, let ocr):
            let data = try requiredPayload(clientRunner { .screenshot(try $0.screenshot()) }, as: Data.self)
            try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
            let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "screenshot", extension: "jpg")
            // Avoid leaving a stale OCR sidecar when the same artifact name is
            // reused with `--no-ocr` or when a new recognition attempt fails.
            let sidecarPath = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("ocr.json").path
            try? FileManager.default.removeItem(atPath: sidecarPath)
            // JPEG persistence and OCR are independent host-side work. Run them in
            // parallel so accurate recognition does not unnecessarily delay the
            // screenshot artifact becoming available.
            let work = DispatchGroup()
            let resultLock = NSLock()
            var imageError: Error?
            var ocrOutput: String?

            work.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { work.leave() }
                do {
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    resultLock.lock()
                    imageError = error
                    resultLock.unlock()
                }
            }

            if ocr {
                work.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { work.leave() }
                    do {
                        let ocrStarted = CFAbsoluteTimeGetCurrent()
                        let result = try OCRService.recognize(data: data)
                        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - ocrStarted) * 1000)
                        let writtenSidecarPath = try OCRService.writeSidecar(result: result, imagePath: path, elapsedMs: elapsedMs)
                        let output = OCRService.format(result) + "OCR sidecar: \(writtenSidecarPath)\n"
                        resultLock.lock()
                        ocrOutput = output
                        resultLock.unlock()
                    } catch {
                        // OCR is an evidence aid. A malformed/unsupported screenshot
                        // must never turn a successful screenshot command into failure.
                        resultLock.lock()
                        ocrOutput = "OCR (accurate): unavailable (\(error))\n"
                        resultLock.unlock()
                    }
                }
            }
            work.wait()
            resultLock.lock()
            let capturedImageError = imageError
            let capturedOCROutput = ocrOutput
            resultLock.unlock()
            if let capturedImageError {
                throw capturedImageError
            }
            ok = true
            var stdout = "Screenshot saved: \(path)\n"
            if let capturedOCROutput {
                stdout += capturedOCROutput
            }
            return DriverCommandResult(stdout: stdout, payload: .screenshot(data))

        case .tap(let target, let offset, let offsetRatio, let traits, let cindex, let postDom):
            let params = try resolveTapParams(target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .element(try $0.tap(target: params.target, traits: traits, cindex: cindex, offset: params.offset, ratio: params.ratio))
            }, as: ForyElementPayload.self)
            let result = try appendPostDomIfNeeded(
                DriverCommandResult(stdout: "Tap\n\(DriverOutput.formatElement(payload))", payload: .element(payload)),
                postDom: postDom,
                clientRunner: clientRunner
            )
            ok = true
            return result

        case .longPress(let target, let duration, let traits, let cindex, let postDom):
            let foryTarget = try resolveTarget(target, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .element(try $0.longPress(target: foryTarget, durationMs: duration, traits: traits, cindex: cindex))
            }, as: ForyElementPayload.self)
            let result = try appendPostDomIfNeeded(
                DriverCommandResult(stdout: "Longpress\n\(DriverOutput.formatElement(payload))", payload: .element(payload)),
                postDom: postDom,
                clientRunner: clientRunner
            )
            ok = true
            return result

        case .input(let tap, let content, let delete, let enter, let traits, let cindex, let postDom):
            let tapTarget = try resolveInputTapTarget(tap, traits: traits, cindex: cindex)
            let deletePrefix = String(repeating: "\u{7F}", count: delete)
            let effectiveContent = deletePrefix + content + (enter ? "\n" : "")
            _ = try clientRunner {
                try $0.input(tap: tapTarget, content: effectiveContent)
                return nil
            }
            let targetDescription = tap.map { " after tapping \"\($0)\"" } ?? ""
            let result = try appendPostDomIfNeeded(
                DriverCommandResult(stdout: "Input \"\(effectiveContent)\"\(targetDescription)\n", payload: nil),
                postDom: postDom,
                clientRunner: clientRunner
            )
            ok = true
            return result

        case .swipe(let to, let from, let dir, let distance, let traits, let cindex, let postDom):
            let params = try resolveSwipeParams(to: to, from: from, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .swipe(try $0.swipe(to: params.to, from: params.from, distance: distance, dir: dir, traits: traits, cindex: cindex))
            }, as: ForySwipePayload.self)
            let result = try appendPostDomIfNeeded(
                DriverCommandResult(stdout: DriverOutput.formatSwipe(payload), payload: .swipe(payload)),
                postDom: postDom,
                clientRunner: clientRunner
            )
            ok = true
            return result

        case .activateApp(let bundleId):
            _ = try clientRunner {
                try $0.activateApp(bundleId: bundleId)
                return nil
            }
            ok = true
            return DriverCommandResult(stdout: "App \(bundleId) activated\n", payload: nil)

        case .terminateApp(let bundleId):
            do {
                _ = try clientRunner {
                    try $0.terminateApp(bundleId: bundleId)
                    return nil
                }
            } catch {
                if IOSUseCLI.isAppNotRunningError(error) {
                    ok = true
                    return DriverCommandResult(stdout: "App \(bundleId) not running, skipped terminate\n", payload: nil)
                }
                throw error
            }
            ok = true
            return DriverCommandResult(stdout: "App \(bundleId) terminated\n", payload: nil)

        case .home:
            _ = try clientRunner {
                try $0.home()
                return nil
            }
            ok = true
            return DriverCommandResult(stdout: "Pressed Home\n", payload: nil)

        case .dismissAlert(let index):
            let payload = try requiredPayload(clientRunner { .alert(try $0.dismissAlert(index: index)) }, as: ForyAlertPayload.self)
            ok = true
            return DriverCommandResult(stdout: DriverOutput.formatAlert(payload), payload: .alert(payload))
        }
    }

    static func validate(action: DriverAction) throws {
        switch action {
        case .tap(let target, let offset, let offsetRatio, let traits, let cindex, _):
            _ = try resolveTapParams(target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex)
        case .longPress(let target, _, let traits, let cindex, _):
            _ = try resolveTarget(target, traits: traits, cindex: cindex)
        case .input(let tap, _, _, _, let traits, let cindex, _):
            _ = try resolveInputTapTarget(tap, traits: traits, cindex: cindex)
        case .swipe(let to, let from, _, _, let traits, let cindex, _):
            _ = try resolveSwipeParams(to: to, from: from, traits: traits, cindex: cindex)
        default:
            break
        }
    }

    private static func appendPostDomIfNeeded(_ result: DriverCommandResult, postDom: PostDomMode?, clientRunner: ClientRunner) throws -> DriverCommandResult {
        guard let postDom else { return result }
        let title: String
        let waitQuiescence: Bool
        switch postDom {
        case .afterQuiescence:
            title = "DOM after quiescence"
            waitQuiescence = true
        case .afterMilliseconds(let domAfterMs):
            if domAfterMs > 0 {
                Thread.sleep(forTimeInterval: Double(domAfterMs) / 1000.0)
            }
            title = "DOM after \(domAfterMs)ms"
            waitQuiescence = false
        }
        let payload = try requiredPayload(clientRunner { .dom(try $0.dom(raw: false, fresh: true, waitQuiescence: waitQuiescence)) }, as: ForyDomPayload.self)
        var stdout = result.stdout
        if !stdout.hasSuffix("\n") {
            stdout += "\n"
        }
        stdout += "\n\(title)\n"
        stdout += DriverOutput.formatDom(payload)
        return DriverCommandResult(stdout: stdout, payload: result.payload)
    }

    private static func appendActionLog(action: String, ok: Bool, elapsedMs: Int, paths: IOSUsePaths) {
        CLILogService.append(paths: paths, [
            "[cli-action] action=\(action) ok=\(ok) elapsed=\(elapsedMs)ms"
        ])
    }

    static func resolveTapParams(
        _ target: String,
        offset: String?,
        offsetRatio: String?,
        traits: String?,
        cindex: Int32?
    ) throws -> (target: ForyTarget, offset: ForyPoint?, ratio: ForyPoint) {
        let foryTarget = try resolveTarget(target, traits: traits, cindex: cindex)
        if foryTarget.point != nil && (offset != nil || offsetRatio != nil) {
            throw CLIParseError.invalidValue("offset requires element label, not absolute point")
        }
        let offsetPoint = try offset.map { try pointPair($0, emptyDefault: 0) }
        let ratioPoint = try offsetPoint == nil
            ? (offsetRatio.map { try pointPair($0, emptyDefault: IOSUseProtocol.defaultTargetRatio) }
                ?? ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio))
            : ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)
        return (foryTarget, offsetPoint, ratioPoint)
    }

    static func resolveSwipeParams(to: String?, from: String?, traits: String?, cindex: Int32?) throws -> (to: ForyTarget, from: ForyTarget) {
        let toTarget = try resolveTarget(to, traits: traits, cindex: cindex)
        let fromTarget = try resolveTarget(from)
        return (toTarget, fromTarget)
    }

    static func resolveInputTapTarget(_ tap: String?, traits: String?, cindex: Int32?) throws -> ForyTarget? {
        guard let tap, !tap.isEmpty else {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("--traits or --cindex require --tap with a label target")
            }
            return nil
        }
        return try resolveTarget(tap, traits: traits, cindex: cindex)
    }

    static func resolveTarget(_ value: String?, traits: String? = nil, cindex: Int32? = nil) throws -> ForyTarget {
        guard let value, !value.isEmpty else {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("traits or cindex require label target")
            }
            return ForyTarget()
        }
        if let point = try? pointPair(value, emptyDefault: 0) {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("point target does not support traits or cindex")
            }
            return ForyTarget(label: "", point: point)
        }
        return ForyTarget(label: value, point: nil, traits: traits ?? "", cindex: cindex)
    }

    static func pointPair(_ value: String, emptyDefault: Double) throws -> ForyPoint {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        let rawX = parts[0].trimmingCharacters(in: .whitespaces)
        let rawY = parts[1].trimmingCharacters(in: .whitespaces)
        let x = rawX.isEmpty ? emptyDefault : Double(rawX)
        let y = rawY.isEmpty ? emptyDefault : Double(rawY)
        guard let x, let y, x.isFinite, y.isFinite else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        return ForyPoint(x: x, y: y)
    }

    private static func requiredPayload<T>(_ payload: DriverCommandPayload?, as type: T.Type) throws -> T {
        let value: Any?
        switch payload {
        case .dom(let payload): value = payload
        case .waitFor(let payload): value = payload
        case .screenshot(let payload): value = payload
        case .element(let payload): value = payload
        case .swipe(let payload): value = payload
        case .alert(let payload): value = payload
        case nil: value = nil
        }
        guard let typed = value as? T else {
            throw CLIParseError.invalidValue("internal error: unexpected driver command payload")
        }
        return typed
    }
}
