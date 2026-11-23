import Foundation
import IOSUseProtocol

enum SandboxContainerScope: String, Equatable, Sendable {
    case container = "data"
    case documents = "documents"

    var vendCommand: String {
        switch self {
        case .container: return "VendContainer"
        case .documents: return "VendDocuments"
        }
    }
}

enum HouseArrestClient {
    static func resolveRemotePath(_ rawPath: String?, scope: SandboxContainerScope) throws -> String {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.contains("\0") else {
            throw CLIParseError.invalidValue("Sandbox path must not contain NUL bytes.")
        }
        let normalizedSlashes = trimmed.replacingOccurrences(of: "\\", with: "/")
        let rawSegments = normalizedSlashes.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var segments: [String] = []
        for segment in rawSegments {
            if segment == ".." {
                throw CLIParseError.invalidValue("Sandbox path must not contain '..': \(trimmed)")
            }
            if segment == "." {
                continue
            }
            segments.append(segment)
        }

        switch scope {
        case .container:
            return segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
        case .documents:
            if segments.isEmpty {
                return "/Documents"
            }
            if segments.first == "Documents" {
                return "/" + segments.joined(separator: "/")
            }
            return "/Documents/" + segments.joined(separator: "/")
        }
    }

    static func isProtectedRoot(_ afcPath: String, scope: SandboxContainerScope) -> Bool {
        switch scope {
        case .container:
            return afcPath == "/"
        case .documents:
            return afcPath == "/" || afcPath == "/Documents"
        }
    }

    static func withClient<T>(
        udid: String,
        bundleID: String,
        scope: SandboxContainerScope,
        serviceConnector: (String, String) throws -> DeviceStream = LockdownSession.connectToService,
        _ body: (AfcClient) throws -> T
    ) throws -> T {
        let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty else {
            throw CLIParseError.invalidValue("App bundle ID must not be empty.")
        }
        let stream = try serviceConnector(IOSUseProtocol.XCConstants.houseArrestServiceName, udid)
        defer { stream.close() }

        let requestBody: [String: Any] = [
            "Command": scope.vendCommand,
            "Identifier": trimmedBundleID,
        ]
        let xml = try serializePlist(requestBody)
        try stream.write(uint32BE(UInt32(xml.count)) + xml)

        let header = try stream.readExact(
            byteCount: 4,
            timeoutSeconds: IOSUseProtocol.XCConstants.lockdownRequestTimeoutSeconds
        )
        let size = Int(readUInt32BE(header, 0))
        guard size > 0, size <= IOSUseProtocol.XCConstants.lockdownMaxPlistSizeBytes else {
            throw CLIParseError.invalidValue("house_arrest plist invalid size: \(size)")
        }
        let response = try parsePlist(
            try stream.readExact(
                byteCount: size,
                timeoutSeconds: IOSUseProtocol.XCConstants.lockdownRequestTimeoutSeconds
            )
        )
        guard response["Status"] as? String == "Complete" else {
            throw formatHandshakeError(
                response: response,
                bundleID: trimmedBundleID,
                udid: udid,
                scope: scope
            )
        }
        return try body(AfcClient(stream: stream))
    }

    private static func formatHandshakeError(
        response: [String: Any],
        bundleID: String,
        udid: String,
        scope: SandboxContainerScope
    ) -> Error {
        let errorCode = response["Error"] as? String ?? ""
        switch errorCode {
        case "ApplicationLookupFailed":
            return CLIParseError.invalidValue("App \(bundleID) is not installed on device \(udid).")
        case "InstallationLookupFailed", "MissingContainer":
            switch scope {
            case .container:
                return CLIParseError.invalidValue(
                    "Cannot open full sandbox container for \(bundleID) on \(udid) (\(errorCode)). "
                        + "Full container access requires a development or enterprise build signed with get-task-allow; "
                        + "pass --documents if the App enables UIFileSharingEnabled."
                )
            case .documents:
                return CLIParseError.invalidValue(
                    "Cannot open Documents container for \(bundleID) on \(udid) (\(errorCode)). "
                        + "Verify that the App is installed and enables UIFileSharingEnabled or get-task-allow."
                )
            }
        default:
            return CLIParseError.invalidValue(
                "house_arrest \(scope.vendCommand) failed for \(bundleID): \(plistResponseSummary(response))"
            )
        }
    }
}
