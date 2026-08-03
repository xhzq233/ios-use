import Foundation
import IOSUseProtocol

enum MachineValue: Encodable, Equatable, Sendable {
    case object([String: MachineValue])
    case array([MachineValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MachineError: Encodable, Equatable {
    var message: String
    var category: String
    var code: String
    var phase: String
    var retryable: Bool
    var fatal: Bool
    var mutationMayHaveApplied: Bool
}

protocol MachineErrorConvertible {
    var machineError: MachineError { get }
}

struct CLIInvocationSnapshot: Equatable, Sendable {
    let interactionState: MachineValue?
    let warnings: [String]
}

final class CLIInvocationState: @unchecked Sendable {
    private let lock = NSLock()
    private var alertRefreshClaimed = false
    private var interactionState: MachineValue?
    private var warnings: [String] = []

    func claimAlertRefresh() -> Bool {
        withLock {
            guard !alertRefreshClaimed else {
                return false
            }
            alertRefreshClaimed = true
            return true
        }
    }

    func suppressAlertRefresh() {
        withLock {
            alertRefreshClaimed = true
        }
    }

    func recordWarning(_ warning: String) {
        guard !warning.isEmpty else {
            return
        }
        withLock {
            if !warnings.contains(warning) {
                warnings.append(warning)
            }
        }
    }

    func recordInteractionState(_ value: MachineValue) {
        withLock {
            interactionState = value
        }
    }

    func snapshot() -> CLIInvocationSnapshot {
        withLock {
            CLIInvocationSnapshot(
                interactionState: interactionState,
                warnings: warnings
            )
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum CLIInvocationContext {
    @TaskLocal
    static var current: CLIInvocationState?
}

struct CLIInvocationPerformanceSnapshot: Equatable, Sendable {
    let alertRefreshElapsedMs: Double?
}

final class CLIInvocationPerformanceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var alertRefreshElapsedMs: Double?
    private var frozenTotalElapsedMs: Double?

    init(
        startedAt: TimeInterval =
            ProcessInfo.processInfo.systemUptime,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.startedAt = startedAt
        self.now = now
    }

    func recordAlertRefresh(elapsedMs: Double) {
        guard elapsedMs.isFinite, elapsedMs >= 0 else {
            return
        }
        withLock {
            alertRefreshElapsedMs =
                (alertRefreshElapsedMs ?? 0) + elapsedMs
        }
    }

    func snapshot() -> CLIInvocationPerformanceSnapshot {
        withLock {
            CLIInvocationPerformanceSnapshot(
                alertRefreshElapsedMs: alertRefreshElapsedMs
            )
        }
    }

    func freezeTotalElapsedMs() -> Double {
        withLock {
            if let frozenTotalElapsedMs {
                return frozenTotalElapsedMs
            }
            let elapsed =
                (now() - startedAt) * 1_000
            let normalized =
                elapsed.isFinite ? max(0, elapsed) : 0
            frozenTotalElapsedMs = normalized
            return normalized
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum CLIInvocationPerformanceContext {
    @TaskLocal
    static var current: CLIInvocationPerformanceCollector?
}

enum MachineOutput {
    private struct SuccessEnvelope: Encodable {
        let schemaVersion = 1
        let ok = true
        let command: String
        let data: MachineValue
        let warnings: [String]
        let interaction: MachineValue?
    }

    private struct FailureEnvelope: Encodable {
        let schemaVersion = 1
        let ok = false
        let command: String
        let data: MachineValue
        let warnings: [String]
        let error: MachineError
        let evidenceManifest: String?
        let interaction: MachineValue?
    }

    private struct InvocationMetadata {
        let warnings: [String]
        let interaction: MachineValue?
    }

    static func success(
        command: String,
        data: MachineValue = .object([:]),
        warnings: [String] = []
    ) -> CLIResult {
        let metadata = invocationMetadata(
            baseWarnings: warnings
        )
        return render(
            SuccessEnvelope(
                command: command,
                data: data,
                warnings: metadata.warnings,
                interaction: metadata.interaction
            ),
            exitCode: 0,
            toStderr: false
        )
    }

    static func failure(
        command: String,
        error: Error,
        data: MachineValue = .object([:]),
        warnings: [String] = [],
        evidenceManifest: String? = nil,
        exitCode: Int32 = 1,
        mutationMayHaveApplied: Bool? = nil
    ) -> CLIResult {
        var classified = classify(error)
        if let mutationMayHaveApplied {
            classified.mutationMayHaveApplied = mutationMayHaveApplied
        }
        var failureData = data
        if let logPath = macLogPath(in: error),
           case .object(var fields) = failureData {
            fields["macLogPath"] = .string(logPath)
            failureData = .object(fields)
        }
        let metadata = invocationMetadata(
            baseWarnings: warnings
        )
        return render(
            FailureEnvelope(
                command: command,
                data: failureData,
                warnings: metadata.warnings,
                error: classified,
                evidenceManifest: evidenceManifest,
                interaction: metadata.interaction
            ),
            exitCode: exitCode,
            toStderr: true
        )
    }

    static func finalizeInvocation(
        _ result: CLIResult,
        expectsMachineOutput: Bool,
        snapshot: CLIInvocationSnapshot
    ) -> CLIResult {
        if expectsMachineOutput {
            return result
        }
        return appendHumanWarnings(snapshot.warnings, to: result)
    }

    static func classify(_ error: Error) -> MachineError {
        if let classified = error as? MachineErrorConvertible {
            return classified.machineError
        }
        if let readinessError = error as? AppLifecycleService.ReadinessError {
            var classified = classify(readinessError.underlying)
            classified.message = readinessError.description
            classified.mutationMayHaveApplied = true
            return classified
        }
        if let readinessError = error as? OpenURLService.ReadinessError {
            var classified = classify(readinessError.underlying)
            classified.message = readinessError.description
            classified.mutationMayHaveApplied = true
            return classified
        }
        if case DriverClientError.driverError(let message, let payload) = error {
            return MachineError(
                message: message,
                category: payload.category,
                code: payload.code,
                phase: payload.phase,
                retryable: payload.retryable,
                fatal: payload.fatal,
                mutationMayHaveApplied: DriverFailureEvidence.mutationMayHaveApplied(errorPayload: payload)
            )
        }
        if let clientError = error as? DriverClientError {
            let code: String
            let retryable: Bool
            let fatal: Bool
            switch clientError {
            case .connectFailed, .connectFailedMessage:
                code = "driver_connect_failed"
                retryable = clientError.isRecoverableConnectFailure
                fatal = false
            case .socketCreateFailed:
                code = "driver_socket_create_failed"
                retryable = true
                fatal = false
            case .readFailed:
                code = "driver_read_failed"
                retryable = true
                fatal = false
            case .writeFailed:
                code = "driver_write_failed"
                retryable = true
                fatal = false
            case .invalidFrameLength, .maxFrameSizeExceeded, .invalidErrorPayload:
                code = "driver_protocol_failed"
                retryable = false
                fatal = true
            case .driverError:
                code = "driver_error"
                retryable = false
                fatal = false
            }
            return MachineError(
                message: clientError.description,
                category: IOSUseErrorCategory.protocolFailure,
                code: code,
                phase: IOSUseErrorPhase.dispatch,
                retryable: retryable,
                fatal: fatal,
                mutationMayHaveApplied: false
            )
        }
        if case DriverCommandExecutionError.postconditionFailed(let label, let underlying) = error {
            let classified = classify(underlying)
            return MachineError(
                message: "\(label) failed after mutation: \(classified.message)",
                category: IOSUseErrorCategory.postcondition,
                code: IOSUseErrorCode.postconditionFailed,
                phase: IOSUseErrorPhase.postcondition,
                retryable: classified.retryable,
                fatal: classified.fatal,
                mutationMayHaveApplied: true
            )
        }
        if let loggedError =
                error as? PlayCoverSessionLoggedLaunchError {
            var classified = classify(loggedError.underlying)
            classified.message = loggedError.description
            return classified
        }
        if let sessionError =
                error as? PlayCoverSessionUnterminatedLaunchError {
            var classified = classify(sessionError.underlying)
            classified.message = sessionError.description
            classified.mutationMayHaveApplied = true
            return classified
        }
        if let rollbackError =
                error as? PlayCoverSessionCommitRollbackError {
            return MachineError(
                message: rollbackError.description,
                category: IOSUseErrorCategory.session,
                code: "mac_session_commit_rollback_failed",
                phase: "mac_session_commit",
                retryable: false,
                fatal: true,
                mutationMayHaveApplied: true
            )
        }
        if let handoffError =
                error as? PlayCoverSessionJournalHandoffError {
            return MachineError(
                message: handoffError.description,
                category: IOSUseErrorCategory.session,
                code: "mac_session_handoff_failed",
                phase: "mac_session_commit",
                retryable: false,
                fatal: true,
                mutationMayHaveApplied: true
            )
        }
        if let cleanupError =
                error as? PlayCoverSessionCleanupError {
            let code: String
            let phase: String
            switch cleanupError.operation {
            case .launch:
                code = "mac_launch_cleanup_failed"
                phase = "mac_launch_cleanup"
            case .stop:
                code = "mac_stop_cleanup_failed"
                phase = "mac_stop_cleanup"
            }
            return MachineError(
                message: cleanupError.description,
                category: IOSUseErrorCategory.session,
                code: code,
                phase: phase,
                retryable: true,
                fatal: false,
                mutationMayHaveApplied: true
            )
        }
        if let launchError = error as? PlayCoverUnterminatedLaunchError {
            return MachineError(
                message: launchError.description,
                category: IOSUseErrorCategory.session,
                code: "mac_launch_rollback_failed",
                phase: "mac_dyld_launch",
                retryable: false,
                fatal: true,
                mutationMayHaveApplied: true
            )
        }
        if let backendError = error as? PlayCoverBackendError {
            let category: String
            let code: String
            let phase: String
            let retryable: Bool
            let fatal: Bool
            switch backendError {
            case .invalidApp:
                category = IOSUseErrorCategory.validation
                code = "mac_invalid_app"
                phase = "mac_inspect"
                retryable = false
                fatal = false
            case .unsupportedMachO:
                category = IOSUseErrorCategory.validation
                code = "mac_unsupported_macho"
                phase = "mac_macho"
                retryable = false
                fatal = false
            case .malformedMachO:
                category = IOSUseErrorCategory.validation
                code = "mac_malformed_macho"
                phase = "mac_macho"
                retryable = false
                fatal = false
            case .encryptedMachO:
                category = IOSUseErrorCategory.validation
                code = "mac_encrypted_macho"
                phase = "mac_macho"
                retryable = false
                fatal = false
            case .duplicateRuntimeLoad:
                category = IOSUseErrorCategory.validation
                code = "mac_duplicate_runtime_load"
                phase = "mac_macho"
                retryable = false
                fatal = false
            case .machOTransformFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "mac_macho_transform_failed"
                phase = "mac_macho"
                retryable = false
                fatal = false
            case .entitlementFailed:
                category = IOSUseErrorCategory.validation
                code = "mac_entitlement_failed"
                phase = "mac_entitlements"
                retryable = false
                fatal = false
            case .codeSigningFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "mac_codesign_failed"
                phase = "mac_codesign"
                retryable = false
                fatal = false
            case .outputExists:
                category = IOSUseErrorCategory.session
                code = "mac_output_exists"
                phase = "mac_prepare"
                retryable = false
                fatal = false
            case .missingRuntime:
                category = IOSUseErrorCategory.validation
                code = "mac_runtime_missing"
                phase = "mac_runtime_source"
                retryable = false
                fatal = false
            case .prepareFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "mac_prepare_failed"
                phase = "mac_prepare"
                retryable = false
                fatal = false
            case .verificationFailed:
                category = IOSUseErrorCategory.validation
                code = "mac_verification_failed"
                phase = "mac_verify"
                retryable = false
                fatal = true
            case .cacheTampered:
                category = IOSUseErrorCategory.validation
                code = "mac_cache_tampered"
                phase = "mac_verify"
                retryable = false
                fatal = true
            case .stdioLogFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "mac_stdio_log_failed"
                phase = "mac_stdio_setup"
                retryable = false
                fatal = false
            case .launchFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "mac_dyld_launch_failed"
                phase = "mac_dyld_launch"
                retryable = false
                fatal = false
            case .launchTimedOut:
                category = IOSUseErrorCategory.timeout
                code = "mac_runtime_hello_timed_out"
                phase = "mac_runtime_hello"
                retryable = true
                fatal = false
            case .terminateFailed:
                category = IOSUseErrorCategory.session
                code = "mac_terminate_failed"
                phase = "mac_stop"
                retryable = false
                fatal = false
            case .capabilityUnavailable:
                category = IOSUseErrorCategory.validation
                code = "mac_capability_unavailable"
                phase = IOSUseErrorPhase.validation
                retryable = false
                fatal = false
            case .bundleAlreadyRunning:
                category = IOSUseErrorCategory.session
                code = "mac_bundle_already_running"
                phase = "mac_preflight"
                retryable = true
                fatal = false
            case .pendingLaunchUnresolved:
                category = IOSUseErrorCategory.session
                code = "mac_pending_launch_unresolved"
                phase = "mac_pending_launch"
                retryable = false
                fatal = false
            }
            return MachineError(
                message: backendError.description,
                category: category,
                code: code,
                phase: phase,
                retryable: retryable,
                fatal: fatal,
                mutationMayHaveApplied: false
            )
        }
        if let parseError = error as? CLIParseError {
            return MachineError(
                message: parseError.description,
                category: IOSUseErrorCategory.validation,
                code: parseError.machineCode,
                phase: IOSUseErrorPhase.validation,
                retryable: false,
                fatal: false,
                mutationMayHaveApplied: false
            )
        }
        return MachineError(
            message: String(describing: error),
            category: IOSUseErrorCategory.protocolFailure,
            code: "command_failed",
            phase: IOSUseErrorPhase.dispatch,
            retryable: false,
            fatal: false,
            mutationMayHaveApplied: false
        )
    }

    private static func macLogPath(
        in error: Error
    ) -> String? {
        if let loggedError =
                error as? PlayCoverSessionLoggedLaunchError {
            return loggedError.logPath
        }
        if let sessionError =
                error as? PlayCoverSessionUnterminatedLaunchError {
            return sessionError.result.logPath
        }
        if let rollbackError =
                error as? PlayCoverSessionCommitRollbackError {
            return rollbackError.result.logPath
        }
        if let handoffError =
                error as? PlayCoverSessionJournalHandoffError {
            return handoffError.result.logPath
        }
        if let cleanupError =
                error as? PlayCoverSessionCleanupError {
            return cleanupError.logPath
        }
        return nil
    }

    private static func invocationMetadata(
        baseWarnings: [String]
    ) -> InvocationMetadata {
        guard let state =
                CLIInvocationContext.current else {
            return InvocationMetadata(
                warnings: baseWarnings,
                interaction: nil
            )
        }
        let snapshot = state.snapshot()
        var warnings = baseWarnings
        for warning in snapshot.warnings
            where !warnings.contains(warning) {
            warnings.append(warning)
        }
        return InvocationMetadata(
            warnings: warnings,
            interaction: snapshot.interactionState
        )
    }

    private static func appendHumanWarnings(
        _ warnings: [String],
        to result: CLIResult
    ) -> CLIResult {
        guard !warnings.isEmpty else {
            return result
        }
        var stderr = result.stderr
        if !stderr.isEmpty, !stderr.hasSuffix("\n") {
            stderr += "\n"
        }
        for warning in warnings {
            let line = warning
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
            stderr += "warning: \(line)\n"
        }
        return CLIResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: stderr
        )
    }

    private static func render<T: Encodable>(_ value: T, exitCode: Int32, toStderr: Bool) -> CLIResult {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
            return toStderr
                ? CLIResult(exitCode: exitCode, stderr: output)
                : CLIResult(exitCode: exitCode, stdout: output)
        } catch {
            return CLIErrorEnvelope(message: "failed to encode JSON output: \(error)", exitCode: 1).render()
        }
    }
}

extension CLIParseError {
    fileprivate var machineCode: String {
        switch self {
        case .missingCommand: return "missing_command"
        case .unknownCommand: return "unknown_command"
        case .unknownOption: return "unknown_option"
        case .missingRequiredOption: return "missing_required_option"
        case .missingRequiredArgument: return "missing_required_argument"
        case .missingOptionValue: return "missing_option_value"
        case .unexpectedArgument: return "unexpected_argument"
        case .invalidValue: return "invalid_value"
        }
    }
}
