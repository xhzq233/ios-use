import Foundation
import IOSUseProtocol

enum MachineValue: Encodable, Equatable {
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

enum MachineOutput {
    private struct SuccessEnvelope: Encodable {
        let schemaVersion = 1
        let ok = true
        let command: String
        let data: MachineValue
        let warnings: [String]
    }

    private struct FailureEnvelope: Encodable {
        let schemaVersion = 1
        let ok = false
        let command: String
        let data: MachineValue
        let warnings: [String]
        let error: MachineError
        let evidenceManifest: String?
    }

    static func success(
        command: String,
        data: MachineValue = .object([:]),
        warnings: [String] = []
    ) -> CLIResult {
        render(
            SuccessEnvelope(command: command, data: data, warnings: warnings),
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
        if let logPath = playCoverLogPath(in: error),
           case .object(var fields) = failureData {
            fields["playcoverLogPath"] = .string(logPath)
            failureData = .object(fields)
        }
        return render(
            FailureEnvelope(
                command: command,
                data: failureData,
                warnings: warnings,
                error: classified,
                evidenceManifest: evidenceManifest
            ),
            exitCode: exitCode,
            toStderr: true
        )
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
                code: "playcover_session_commit_rollback_failed",
                phase: "playcover_session_commit",
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
                code: "playcover_session_handoff_failed",
                phase: "playcover_session_commit",
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
                code = "playcover_launch_cleanup_failed"
                phase = "playcover_launch_cleanup"
            case .stop:
                code = "playcover_stop_cleanup_failed"
                phase = "playcover_stop_cleanup"
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
                code: "playcover_launch_rollback_failed",
                phase: "playcover_dyld_launch",
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
                code = "playcover_invalid_app"
                phase = "playcover_inspect"
                retryable = false
                fatal = false
            case .unsupportedMachO:
                category = IOSUseErrorCategory.validation
                code = "playcover_unsupported_macho"
                phase = "playcover_macho"
                retryable = false
                fatal = false
            case .malformedMachO:
                category = IOSUseErrorCategory.validation
                code = "playcover_malformed_macho"
                phase = "playcover_macho"
                retryable = false
                fatal = false
            case .encryptedMachO:
                category = IOSUseErrorCategory.validation
                code = "playcover_encrypted_macho"
                phase = "playcover_macho"
                retryable = false
                fatal = false
            case .duplicateRuntimeLoad:
                category = IOSUseErrorCategory.validation
                code = "playcover_duplicate_runtime_load"
                phase = "playcover_macho"
                retryable = false
                fatal = false
            case .machOTransformFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "playcover_macho_transform_failed"
                phase = "playcover_macho"
                retryable = false
                fatal = false
            case .entitlementFailed:
                category = IOSUseErrorCategory.validation
                code = "playcover_entitlement_failed"
                phase = "playcover_entitlements"
                retryable = false
                fatal = false
            case .codeSigningFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "playcover_codesign_failed"
                phase = "playcover_codesign"
                retryable = false
                fatal = false
            case .outputExists:
                category = IOSUseErrorCategory.session
                code = "playcover_output_exists"
                phase = "playcover_prepare"
                retryable = false
                fatal = false
            case .missingRuntime:
                category = IOSUseErrorCategory.validation
                code = "playcover_runtime_missing"
                phase = "playcover_runtime_source"
                retryable = false
                fatal = false
            case .prepareFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "playcover_prepare_failed"
                phase = "playcover_prepare"
                retryable = false
                fatal = false
            case .verificationFailed:
                category = IOSUseErrorCategory.validation
                code = "playcover_verification_failed"
                phase = "playcover_verify"
                retryable = false
                fatal = true
            case .cacheTampered:
                category = IOSUseErrorCategory.validation
                code = "playcover_cache_tampered"
                phase = "playcover_verify"
                retryable = false
                fatal = true
            case .stdioLogFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "playcover_stdio_log_failed"
                phase = "playcover_stdio_setup"
                retryable = false
                fatal = false
            case .launchFailed:
                category = IOSUseErrorCategory.internalFailure
                code = "playcover_dyld_launch_failed"
                phase = "playcover_dyld_launch"
                retryable = false
                fatal = false
            case .launchTimedOut:
                category = IOSUseErrorCategory.timeout
                code = "playcover_runtime_hello_timed_out"
                phase = "playcover_runtime_hello"
                retryable = true
                fatal = false
            case .terminateFailed:
                category = IOSUseErrorCategory.session
                code = "playcover_terminate_failed"
                phase = "playcover_stop"
                retryable = false
                fatal = false
            case .capabilityUnavailable:
                category = IOSUseErrorCategory.validation
                code = "playcover_capability_unavailable"
                phase = IOSUseErrorPhase.validation
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

    private static func playCoverLogPath(
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
