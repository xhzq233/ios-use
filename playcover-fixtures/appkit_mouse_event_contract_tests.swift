import Foundation

private struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

private enum ContractFailure: Error, CustomStringConvertible {
    case usage
    case failed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: appkit_mouse_event_contract_tests <compiled-helper>"
        case .failed(let message):
            return message
        }
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw ContractFailure.failed(message)
    }
}

private func run(
    _ executable: String,
    _ arguments: [String]
) throws -> CommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr: String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func screens(
    from result: CommandResult
) throws -> [[String: Any]] {
    try require(
        result.status == 0,
        "--screens failed: \(result.stderr)"
    )
    let raw = try JSONSerialization.jsonObject(with: result.stdout)
    guard
        let object = raw as? [String: Any],
        object["operation"] as? String == "screens",
        object["postEventAccessRequired"] as? Bool == false,
        object["lockedSessionAllowed"] as? Bool == true,
        let rows = object["screens"] as? [[String: Any]],
        (object["screenCount"] as? NSNumber)?.intValue == rows.count,
        let mainDisplayID =
            (object["mainDisplayID"] as? NSNumber)?.uint32Value
    else {
        throw ContractFailure.failed(
            "--screens did not return the stable topology envelope"
        )
    }
    try require(!rows.isEmpty, "--screens returned no displays")
    var priorDisplayID: UInt32?
    var displayIDs = Set<UInt32>()
    for row in rows {
        guard
            let displayID =
                (row["screenDisplayID"] as? NSNumber)?.uint32Value,
            let isMain = row["screenIsMain"] as? Bool,
            let hasNSScreen = row["hasNSScreen"] as? Bool,
            row["cgBounds"] is [String: Any],
            row["active"] is Bool,
            row["online"] is Bool,
            row["mirrored"] is Bool,
            row["builtin"] is Bool
        else {
            throw ContractFailure.failed(
                "--screens row is missing stable display fields"
            )
        }
        if let priorDisplayID {
            try require(
                priorDisplayID < displayID,
                "--screens rows are not uniquely sorted by display ID"
            )
        }
        priorDisplayID = displayID
        displayIDs.insert(displayID)
        try require(
            isMain == (displayID == mainDisplayID),
            "screenIsMain disagrees with mainDisplayID"
        )
        if hasNSScreen {
            try require(
                row["frame"] is [String: Any] &&
                    row["visibleFrame"] is [String: Any] &&
                    row["backingScaleFactor"] is NSNumber,
                "NSScreen-backed row is missing AppKit geometry"
            )
        }
    }
    try require(
        displayIDs.contains(mainDisplayID),
        "main display is absent from --screens"
    )
    return rows
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else {
        throw ContractFailure.usage
    }
    let executable = arguments[1]
    let firstRows = try screens(
        from: run(executable, ["--screens"])
    )
    let secondRows = try screens(
        from: run(executable, ["--screens"])
    )
    let firstIDs = firstRows.compactMap {
        ($0["screenDisplayID"] as? NSNumber)?.uint32Value
    }
    let secondIDs = secondRows.compactMap {
        ($0["screenDisplayID"] as? NSNumber)?.uint32Value
    }
    try require(
        firstIDs == secondIDs,
        "--screens display ordering changed across consecutive reads"
    )

    let invalidExpected = try run(
        executable,
        ["0", "0", "1", "1", "0"]
    )
    try require(
        invalidExpected.status != 0 &&
            invalidExpected.stderr.contains(
                "invalid expected-window-number"
            ),
        "expected window number was not parsed before event access"
    )
    let legacy = try run(
        executable,
        ["0", "0", "1", String(Int32.max)]
    )
    try require(
        legacy.status != 0 && !legacy.stderr.contains("usage:"),
        "legacy click argument shape is no longer accepted"
    )
    FileHandle.standardError.write(
        Data(
            "[appkit-mouse-event-contract] screens=\(firstRows.count) pass=1\n"
                .utf8
        )
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
