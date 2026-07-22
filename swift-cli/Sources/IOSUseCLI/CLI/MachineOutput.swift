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
        return render(
            FailureEnvelope(
                command: command,
                data: data,
                warnings: warnings,
                error: classified,
                evidenceManifest: evidenceManifest
            ),
            exitCode: exitCode,
            toStderr: true
        )
    }

    static func classify(_ error: Error) -> MachineError {
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
