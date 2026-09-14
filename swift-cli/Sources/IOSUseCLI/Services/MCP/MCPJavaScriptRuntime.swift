import Foundation
import MCP
import QuickJSC

/// One stdio client owns one JavaScript context. Device connections live in
/// that context's Host; requests never share a context across server processes.
final class MCPJavaScriptRuntime: @unchecked Sendable {
    private let paths: IOSUsePaths
    private let queue = DispatchQueue(label: "ios-use.mcp.javascript")
    private let stateLock = NSLock()
    private var current: MCPExecution?
    private var resetting = false
    private var closed = false
    // Accessed only on queue.
    private var kernel: MCPJavaScriptKernel?

    init(paths: IOSUsePaths) {
        self.paths = paths
    }

    func execute(code: String, timeoutMS: Int) async -> CallTool.Result {
        let execution = MCPExecution()
        guard begin(execution) else {
            return Self.failure("Another JavaScript execution or reset is in progress. Await it, or use js_reset to interrupt it.")
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result: CallTool.Result
                    do {
                        if let reason = execution.reason {
                            result = Self.failure(reason)
                        } else {
                            if kernel == nil {
                                kernel = try MCPJavaScriptKernel(paths: paths)
                            }
                            let activeKernel = kernel!
                            execution.attach(activeKernel)
                            result = try activeKernel.execute(code: code, timeoutMS: timeoutMS, execution: execution)
                        }
                    } catch {
                        result = Self.failure("JavaScript execution failed: \(error)")
                        kernel?.interrupt()
                    }
                    if execution.reason != nil || kernel?.isRunning == false {
                        kernel?.close()
                        kernel = nil
                    }
                    execution.finish()
                    stateLock.lock()
                    if current === execution { current = nil }
                    stateLock.unlock()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            execution.cancel("JavaScript execution cancelled; its context was reset. Observe the Device before retrying any action.")
        }
    }

    func reset() async -> CallTool.Result {
        guard let interrupted = beginReset() else {
            return Self.failure("A JavaScript reset is already in progress.")
        }
        interrupted.execution?.cancel("JavaScript execution interrupted by js_reset.")
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                kernel?.close()
                kernel = nil
                stateLock.lock()
                resetting = false
                stateLock.unlock()
                continuation.resume(returning: .init(content: [
                    .text(text: "JavaScript context reset. Device Drivers and Apps were not stopped.", annotations: nil, _meta: nil)
                ]))
            }
        }
    }

    func close() {
        stateLock.lock()
        closed = true
        let execution = current
        stateLock.unlock()
        execution?.cancel("MCP client disconnected; JavaScript context closed.")
        queue.sync {
            kernel?.close()
            kernel = nil
        }
    }

    func interrupt() {
        stateLock.lock()
        let execution = current
        stateLock.unlock()
        execution?.cancel("MCP server interrupted; JavaScript context closed.")
    }

    private func begin(_ execution: MCPExecution) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, !resetting, current == nil else { return false }
        current = execution
        return true
    }

    private struct ResetState { let execution: MCPExecution? }

    private func beginReset() -> ResetState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, !resetting else { return nil }
        resetting = true
        return ResetState(execution: current)
    }

    private static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

private final class MCPExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted: String?
    private var complete = false
    private weak var kernel: MCPJavaScriptKernel?

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func attach(_ kernel: MCPJavaScriptKernel) {
        lock.lock()
        self.kernel = kernel
        let cancel = interrupted != nil
        lock.unlock()
        if cancel { kernel.interrupt() }
    }

    func cancel(_ reason: String) {
        lock.lock()
        guard !complete, interrupted == nil else { lock.unlock(); return }
        interrupted = reason
        let activeKernel = kernel
        lock.unlock()
        activeKernel?.interrupt()
    }

    func finish() {
        lock.lock()
        complete = true
        kernel = nil
        lock.unlock()
    }
}

private final class MCPJavaScriptKernel: @unchecked Sendable {
    private let host: MCPRuntimeHost
    private let cancellation = MCPKernelCancellation()
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "ios-use.mcp.engine")
    private let queueKey = DispatchSpecificKey<Bool>()
    // All engine state below is confined to queue.
    private var runtime: OpaquePointer?
    private var context: OpaquePointer?
    private var attach = JSValue.undefined
    private var reportError = JSValue.undefined
    private var active: Turn?
    private var nextTimer = 1
    private var rejections: [UnsafeMutableRawPointer: (JSValue, JSValue)] = [:]

    private final class Callback {
        var value: JSValue?
        init(_ value: JSValue) { self.value = value }
    }

    private final class Turn {
        var content: [Tool.Content] = []
        var pending: [Callback] = []
        var timers: [Int: (DispatchWorkItem, JSValue)] = [:]
        var scriptComplete = false
        var isError = false
        var finished = false
    }

    init(paths: IOSUsePaths) throws {
        host = MCPRuntimeHost(paths: paths)
        queue.setSpecific(key: queueKey, value: true)
        try withEngine {
            guard let runtime = JS_NewRuntime() else { throw EngineError("Unable to create JavaScript runtime") }
            self.runtime = runtime
            JS_SetMemoryLimit(runtime, 512 * 1024 * 1024)
            JS_SetInterruptHandler(runtime, { _, opaque in
                guard let opaque else { return 0 }
                return Unmanaged<MCPKernelCancellation>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(cancellation).toOpaque())
            guard let context = JS_NewContext(runtime) else { throw EngineError("Unable to create JavaScript context") }
            self.context = context
            let owner = Unmanaged.passUnretained(self).toOpaque()
            JS_SetContextOpaque(context, owner)
            JS_SetHostPromiseRejectionTracker(runtime, { context, promise, reason, handled, opaque in
                guard let context, let opaque, let key = promise.u.ptr else { return }
                let kernel = Unmanaged<MCPJavaScriptKernel>.fromOpaque(opaque).takeUnretainedValue()
                if let old = kernel.rejections.removeValue(forKey: key) {
                    JS_FreeValue(context, old.0)
                    JS_FreeValue(context, old.1)
                }
                if handled == 0 {
                    kernel.rejections[key] = (JS_DupValue(context, promise), JS_DupValue(context, reason))
                }
            }, owner)

            // Only the bootstrap closure receives native functions. Evaluated
            // scripts have no module loader, filesystem, network or process API.
            let functions = [("nativeCall", 4), ("emitText", 1), ("emitBytes", 2),
                ("decodeBase64", 1), ("scheduleTimer", 2), ("cancelTimer", 1), ("complete", 1)]
                .enumerated().map { index, entry in
                    JS_NewCFunctionMagic(context, { context, _, count, args, magic in
                        guard let context, let owner = JS_GetContextOpaque(context) else { return .exception }
                        let kernel = Unmanaged<MCPJavaScriptKernel>.fromOpaque(owner).takeUnretainedValue()
                        do {
                            return try kernel.invoke(Int(magic), Array(UnsafeBufferPointer(start: args, count: Int(count))))
                        } catch {
                            let value = JS_NewError(context)
                            JS_SetPropertyStr(context, value, "message", kernel.stringValue(String(describing: error)))
                            return JS_Throw(context, value)
                        }
                    }, entry.0, Int32(entry.1), JS_CFUNC_generic_magic, Int32(index))
                }
            defer { functions.forEach { JS_FreeValue(context, $0) } }
            let bootstrap = try evaluate(MCPJavaScriptSource.code)
            defer { JS_FreeValue(context, bootstrap) }
            let helpers = try call(bootstrap, arguments: functions)
            defer { JS_FreeValue(context, helpers) }
            attach = JS_GetPropertyStr(context, helpers, "attach")
            reportError = JS_GetPropertyStr(context, helpers, "reportError")
        }
    }

    deinit { close() }

    var isRunning: Bool { !cancellation.isCancelled }

    func execute(code: String, timeoutMS: Int, execution: MCPExecution) throws -> CallTool.Result {
        let timeout = DispatchWorkItem {
            execution.cancel("JavaScript execution timed out after \(timeoutMS) ms; its context was reset. Device actions already issued may have applied; observe before retrying.")
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(timeoutMS), execute: timeout)
        defer { timeout.cancel() }
        let turn = Turn()
        withEngine {
            active = turn
            do {
                let promise = try evaluate(code, flags: JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC)
                defer { JS_FreeValue(context, promise) }
                let result = try call(attach, arguments: [promise])
                JS_FreeValue(context, result)
            } catch { fail(turn, error) }
            drain(turn)
        }
        wake.wait()
        return withEngine {
            execution.finish()
            clear(turn)
            active = nil
            if let reason = execution.reason {
                turn.content.append(.text(text: reason, annotations: nil, _meta: nil))
                turn.isError = true
            }
            return .init(content: turn.content, isError: turn.isError)
        }
    }

    private func invoke(_ operation: Int, _ args: [JSValue]) throws -> JSValue {
        guard let turn = active, !turn.finished, !cancellation.isCancelled else {
            throw EngineError("This JavaScript execution has ended")
        }
        switch operation {
        case 0: // nativeCall(name, deviceID, options, resolve)
            guard args.count == 4, JS_IsFunction(context, args[3]) != 0,
                  case .object(let options) = try readValue(args[2]) else { throw EngineError("Invalid native call") }
            let name = try text(args[0])
            let deviceID = JS_IsString(args[1]) != 0 ? try text(args[1]) : nil
            let callback = Callback(JS_DupValue(context, args[3]))
            turn.pending.append(callback)
            let host = self.host
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak turn] in
                let result = host.call(name, deviceID: deviceID, options: options)
                self?.queue.async { [weak self, weak turn] in
                    guard let self, let turn else { return }
                    self.withEngine {
                        guard self.active === turn, !turn.finished, !self.cancellation.isCancelled,
                              let function = callback.value else { return }
                        callback.value = nil
                        turn.pending.removeAll { $0 === callback }
                        defer { JS_FreeValue(self.context, function) }
                        let value = JS_NewObject(self.context)
                        JS_SetPropertyStr(self.context, value, "data", self.makeValue(result.data))
                        JS_SetPropertyStr(self.context, value, "image", result.image.map(self.bytesValue) ?? .null)
                        JS_SetPropertyStr(self.context, value, "error", result.error.map(self.makeValue) ?? .null)
                        defer { JS_FreeValue(self.context, value) }
                        do { JS_FreeValue(self.context, try self.call(function, arguments: [value])) }
                        catch { self.fail(turn, error) }
                        self.drain(turn)
                    }
                }
            }
            return .undefined
        case 1:
            guard args.count == 1 else { throw EngineError("write requires a value") }
            turn.content.append(.text(text: try text(args[0]), annotations: nil, _meta: nil))
        case 2:
            guard args.count == 2 else { throw EngineError("emitImage requires image bytes") }
            var length = 0
            guard let bytes = JS_GetArrayBuffer(context, &length, args[0]) else { throw exception() }
            let data = Data(bytes: bytes, count: length)
            turn.content.append(.image(data: data.base64EncodedString(), mimeType: try text(args[1]), annotations: nil, _meta: nil))
        case 3:
            guard args.count == 1, let data = try Data(base64Encoded: text(args[0])) else { throw EngineError("Invalid base64 image") }
            return bytesValue(data)
        case 4:
            guard args.count == 2, JS_IsFunction(context, args[0]) != 0 else { throw EngineError("setTimeout requires a callback") }
            let milliseconds = try number(args[1])
            let seconds = milliseconds.isFinite ? max(0, min(milliseconds, 2_147_483_647)) / 1000 : 0
            let id = nextTimer
            nextTimer += 1
            let work = DispatchWorkItem { [weak self, weak turn] in
                guard let self, let turn else { return }
                self.withEngine {
                    guard self.active === turn, !turn.finished, !self.cancellation.isCancelled,
                          let (_, callback) = turn.timers.removeValue(forKey: id) else { return }
                    defer { JS_FreeValue(self.context, callback) }
                    do { JS_FreeValue(self.context, try self.call(callback)) }
                    catch { self.fail(turn, error) }
                    self.drain(turn)
                }
            }
            turn.timers[id] = (work, JS_DupValue(context, args[0]))
            queue.asyncAfter(deadline: .now() + seconds, execute: work)
            return JS_NewInt64(context, Int64(id))
        case 5:
            if args.count == 1, let id = Int(exactly: try number(args[0])),
               let (work, callback) = turn.timers.removeValue(forKey: id) {
                work.cancel()
                JS_FreeValue(context, callback)
            }
        case 6:
            turn.scriptComplete = true
            turn.isError = turn.isError || (args.first.map { JS_ToBool(context, $0) != 0 } ?? false)
        default: throw EngineError("Unknown native function")
        }
        return .undefined
    }

    private func drain(_ turn: Turn) {
        var jobContext: OpaquePointer?
        while true {
            let result = JS_ExecutePendingJob(runtime, &jobContext)
            if result == 0 { break }
            if result < 0 { fail(turn, exception()); break }
        }
        let rejected = Array(rejections.values)
        rejections.removeAll()
        for (promise, reason) in rejected {
            defer { JS_FreeValue(context, promise); JS_FreeValue(context, reason) }
            if !cancellation.isCancelled {
                do { JS_FreeValue(context, try call(reportError, arguments: [reason])) }
                catch { fail(turn, error) }
            }
            turn.isError = true
            turn.scriptComplete = true
        }
        guard !turn.finished, turn.scriptComplete, turn.pending.isEmpty else { return }
        turn.finished = true
        clearTimers(turn)
        wake.signal()
    }

    private func fail(_ turn: Turn, _ error: Error) {
        turn.content.append(.text(text: "JavaScript error: \(error)", annotations: nil, _meta: nil))
        turn.isError = true
        turn.scriptComplete = true
    }

    private func clearTimers(_ turn: Turn) {
        for (work, callback) in turn.timers.values {
            work.cancel()
            JS_FreeValue(context, callback)
        }
        turn.timers.removeAll()
    }

    private func clear(_ turn: Turn) {
        turn.finished = true
        clearTimers(turn)
        for callback in turn.pending {
            if let value = callback.value { JS_FreeValue(context, value); callback.value = nil }
        }
        turn.pending.removeAll()
    }

    func interrupt() {
        guard cancellation.cancel() else { return }
        host.cancel()
        wake.signal()
    }

    func close() {
        interrupt()
        withEngine {
            guard context != nil else {
                if let runtime { JS_FreeRuntime(runtime); self.runtime = nil }
                return
            }
            if let active { clear(active) }
            active = nil
            for (promise, reason) in rejections.values {
                JS_FreeValue(context, promise)
                JS_FreeValue(context, reason)
            }
            rejections.removeAll()
            JS_FreeValue(context, attach)
            JS_FreeValue(context, reportError)
            JS_FreeContext(context)
            context = nil
            JS_FreeRuntime(runtime)
            runtime = nil
        }
    }

    private func withEngine<T>(_ body: () throws -> T) rethrows -> T {
        // A serial queue may resume on another thread. QuickJS explicitly
        // supports that when its native stack top is refreshed on entry.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            if let runtime { JS_UpdateStackTop(runtime) }
            return try body()
        }
        return try queue.sync {
            if let runtime { JS_UpdateStackTop(runtime) }
            return try body()
        }
    }

    private func evaluate(_ code: String, flags: Int32 = JS_EVAL_TYPE_GLOBAL) throws -> JSValue {
        let utf8 = code.utf8CString
        let value = utf8.withUnsafeBufferPointer {
            JS_Eval(context, $0.baseAddress, $0.count - 1, "<ios-use-mcp>", flags)
        }
        if JS_IsException(value) != 0 { throw exception() }
        return value
    }

    private func call(_ function: JSValue, arguments: [JSValue] = []) throws -> JSValue {
        var args = arguments
        let value = args.withUnsafeMutableBufferPointer { JS_Call(context, function, .undefined, Int32($0.count), $0.baseAddress) }
        if JS_IsException(value) != 0 { throw exception() }
        return value
    }

    private func exception() -> EngineError {
        let error = JS_GetException(context)
        defer { JS_FreeValue(context, error) }
        let message = (try? text(error)) ?? "JavaScript exception"
        if JS_IsError(context, error) != 0 {
            let stack = JS_GetPropertyStr(context, error, "stack")
            defer { JS_FreeValue(context, stack) }
            return EngineError(message + ((try? text(stack)).map { "\n" + $0 } ?? ""))
        }
        return EngineError(message)
    }

    private func text(_ value: JSValue) throws -> String {
        var length = 0
        guard let chars = JS_ToCStringLen(context, &length, value) else {
            // A thrown Symbol or custom toString must not poison later calls.
            let error = JS_GetException(context)
            JS_FreeValue(context, error)
            throw EngineError("Value cannot be converted to text")
        }
        defer { JS_FreeCString(context, chars) }
        return String(decoding: UnsafeRawBufferPointer(start: chars, count: length), as: UTF8.self)
    }

    private func number(_ value: JSValue) throws -> Double {
        var number = 0.0
        guard JS_ToFloat64(context, &number, value) == 0 else { throw exception() }
        return number
    }

    private func stringValue(_ text: String) -> JSValue {
        let utf8 = text.utf8CString
        return utf8.withUnsafeBufferPointer { JS_NewStringLen(context, $0.baseAddress, $0.count - 1) }
    }

    private func bytesValue(_ data: Data) -> JSValue {
        data.withUnsafeBytes { JS_NewArrayBufferCopy(context, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }

    private func makeValue(_ value: MachineValue) -> JSValue {
        switch value {
        case .object(let fields):
            let object = JS_NewObject(context)
            for (key, value) in fields { JS_SetPropertyStr(context, object, key, makeValue(value)) }
            return object
        case .array(let values):
            let array = JS_NewArray(context)
            for (index, value) in values.enumerated() { JS_SetPropertyUint32(context, array, UInt32(index), makeValue(value)) }
            return array
        case .string(let value): return stringValue(value)
        case .integer(let value): return JS_NewInt64(context, Int64(value))
        case .double(let value): return JS_NewFloat64(context, value)
        case .boolean(let value): return JS_NewBool(context, value ? 1 : 0)
        case .null: return .null
        }
    }

    /// Only bootstrap-created argument objects cross this boundary.
    private func readValue(_ value: JSValue) throws -> MachineValue {
        if JS_IsString(value) != 0 { return .string(try text(value)) }
        if JS_IsBool(value) != 0 { return .boolean(JS_ToBool(context, value) != 0) }
        if JS_IsNumber(value) != 0 { return .double(try number(value)) }
        if JS_IsNull(value) != 0 || JS_IsUndefined(value) != 0 { return .null }
        if JS_IsArray(context, value) == 1 {
            let countValue = JS_GetPropertyStr(context, value, "length")
            defer { JS_FreeValue(context, countValue) }
            let count = Int(try number(countValue))
            return .array(try (0..<count).map { index in
                let child = JS_GetPropertyUint32(context, value, UInt32(index))
                defer { JS_FreeValue(context, child) }
                return try readValue(child)
            })
        }
        var properties: UnsafeMutablePointer<JSPropertyEnum>?
        var count: UInt32 = 0
        guard JS_GetOwnPropertyNames(context, &properties, &count, value, Int32(JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)) == 0 else { throw exception() }
        defer { JS_FreePropertyEnum(context, properties, count) }
        var fields: [String: MachineValue] = [:]
        for index in 0..<Int(count) {
            let atom = properties![index].atom
            let key = JS_AtomToString(context, atom)
            let child = JS_GetProperty(context, value, atom)
            defer { JS_FreeValue(context, key); JS_FreeValue(context, child) }
            if JS_IsException(child) != 0 { throw exception() }
            fields[try text(key)] = try readValue(child)
        }
        return .object(fields)
    }

    private struct EngineError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private final class MCPKernelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        cancelled = true
        return true
    }
}

private extension JSValue {
    static var null: JSValue { JSValue(u: JSValueUnion(uint64: 0), tag: Int64(JS_TAG_NULL)) }
    static var undefined: JSValue { JSValue(u: JSValueUnion(uint64: 0), tag: Int64(JS_TAG_UNDEFINED)) }
    static var exception: JSValue { JSValue(u: JSValueUnion(uint64: 0), tag: Int64(JS_TAG_EXCEPTION)) }
}
