import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverPendingLaunchRecoveryError:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    let message: String

    var description: String {
        "Mac pending launch recovery failed: \(message)"
    }
}

/// The recovery authority for a submitted PlayCover launch.
///
/// This type deliberately does not infer safety from age, a missing Runtime
/// socket, or an empty AppKit query. `Decision` is derived only from durable
/// submission evidence, an exact owned process identity, the current boot,
/// and a complete same-UID process-table census. LaunchServices starts the
/// target as the invoking user, so unrelated system-user processes are outside
/// this launch authority and must not make recovery permanently unverifiable.
enum PlayCoverPendingLaunchRecovery {
    struct Evidence: Equatable, Sendable {
        let sessionID: String
        let runtimeSocketPath: String
        let bundleIdentifier: String
        let executablePath: String
        let submissionBootSessionUUID: String?
        let terminalCallbackRecorded: Bool
        let owner: Owner?

        init(
            sessionID: String,
            runtimeSocketPath: String,
            bundleIdentifier: String,
            executablePath: String,
            submissionBootSessionUUID: String?,
            terminalCallbackRecorded: Bool,
            owner: Owner?
        ) {
            self.sessionID = sessionID
            self.runtimeSocketPath = runtimeSocketPath
            self.bundleIdentifier = bundleIdentifier
            self.executablePath = executablePath
            self.submissionBootSessionUUID =
                submissionBootSessionUUID
            self.terminalCallbackRecorded =
                terminalCallbackRecorded
            self.owner = owner
        }
    }

    enum OwnerSource: String, Equatable, Sendable {
        case workspaceCallback
        case authenticatedRuntime
        case directSpawn
    }

    struct Owner: Equatable, Sendable {
        let pid: Int32
        let processBirthMicroseconds: UInt64
        let source: OwnerSource
    }

    struct Candidate: Equatable, Sendable {
        let pid: Int32
        let processBirthMicroseconds: UInt64?
    }

    struct ForeignSession: Equatable, Sendable {
        let sessionID: String
        let runtimeSocketPath: String
    }

    struct SystemObservation: Equatable, Sendable {
        let bootSessionUUID: String
        let census: Census
    }

    enum Census: Equatable, Sendable {
        case complete([Candidate])
        case incomplete(
            candidates: [Candidate],
            reason: String
        )

        var candidates: [Candidate] {
            switch self {
            case .complete(let candidates):
                return candidates
            case .incomplete(let candidates, _):
                return candidates
            }
        }

        var provesEmpty: Bool {
            if case .complete(let candidates) = self {
                return candidates.isEmpty
            }
            return false
        }

        var isComplete: Bool {
            if case .complete = self {
                return true
            }
            return false
        }
    }

    enum OwnedProcessState: Equatable, Sendable {
        case running(
            executablePath: String,
            processBirthMicroseconds: UInt64?
        )
        case missing
        case unverifiable(errno: Int32)
    }

    enum CleanupProof: String, Equatable, Sendable {
        case neverSubmitted
        case ownedProcessExited
        case ownedPIDReused
        case terminalCallbackAndEmptyCensus
        case newBootAndEmptyCensus
    }

    enum Decision: Equatable, Sendable {
        case safeCleanup(CleanupProof)
        case authenticatedOwner(Owner)
        case ownedProcessLive(Owner)
        case unresolved(String)
    }

    static var bootSessionUUIDOverrideForTesting:
        (() throws -> String)?
    static var exactExecutableCensusOverrideForTesting:
        ((String) -> Census)?
    static var ownedProcessStateOverrideForTesting:
        ((Int32) -> OwnedProcessState)?
    static var candidateAuthenticationOverrideForTesting:
        ((Candidate, Evidence) throws -> Bool)?

    /// Pure recovery policy. Callers may persist an authenticated owner and
    /// evaluate again; read-only status callers may report it without writing.
    static func decide(
        evidence: Evidence,
        currentBootSessionUUID: String,
        census: Census,
        ownedProcessState: OwnedProcessState?,
        authenticatedOwner: Owner?,
        candidateAuthenticationComplete: Bool = false
    ) -> Decision {
        guard let submissionBootSessionUUID =
                evidence.submissionBootSessionUUID else {
            return .safeCleanup(.neverSubmitted)
        }

        if let owner = evidence.owner {
            guard let ownedProcessState else {
                return .unresolved(
                    "owned process identity was not inspected"
                )
            }
            return decideOwnedProcess(
                owner: owner,
                expectedExecutablePath: evidence.executablePath,
                state: ownedProcessState
            )
        }

        if let authenticatedOwner {
            return .authenticatedOwner(authenticatedOwner)
        }

        let sameBoot =
            canonicalBootSessionUUID(submissionBootSessionUUID)
                == canonicalBootSessionUUID(
                    currentBootSessionUUID
                )
        if !sameBoot {
            // A process from the recorded boot cannot survive the boot
            // boundary. Same-executable processes on the current boot may
            // belong to another logical Home and are not negative evidence.
            return .safeCleanup(.newBootAndEmptyCensus)
        }

        if evidence.terminalCallbackRecorded {
            if census.provesEmpty
                || candidateAuthenticationComplete {
                return .safeCleanup(
                    .terminalCallbackAndEmptyCensus
                )
            }
            return .unresolved(
                censusUnresolvedReason(
                    prefix:
                        "terminal callback is durable, but an empty "
                        + "session-specific candidate authentication "
                        + "was not completed",
                    census: census
                )
            )
        }

        return .unresolved(
            "the launch was armed on the current boot without a "
                + "durable terminal callback or exact owned process"
        )
    }

    static func currentBootSessionUUID() throws -> String {
        if let bootSessionUUIDOverrideForTesting {
            return try validateBootSessionUUID(
                bootSessionUUIDOverrideForTesting()
            )
        }
        #if canImport(Darwin)
        var byteCount: size_t = 0
        guard Darwin.sysctlbyname(
                "kern.bootsessionuuid",
                nil,
                &byteCount,
                nil,
                0
              ) == 0,
              byteCount > 1,
              byteCount <= 128 else {
            throw PlayCoverPendingLaunchRecoveryError(
                message:
                    "cannot size kern.bootsessionuuid: errno \(errno)"
            )
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBufferPointer {
            Darwin.sysctlbyname(
                "kern.bootsessionuuid",
                $0.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0 else {
            throw PlayCoverPendingLaunchRecoveryError(
                message:
                    "cannot read kern.bootsessionuuid: errno \(errno)"
            )
        }
        let payload = bytes.prefix(byteCount)
        guard payload.last == 0,
              !payload.dropLast().contains(0),
              let value = String(
                bytes: payload.dropLast(),
                encoding: .utf8
              ) else {
            throw PlayCoverPendingLaunchRecoveryError(
                message: "kern.bootsessionuuid is malformed"
            )
        }
        return try validateBootSessionUUID(value)
        #else
        throw PlayCoverPendingLaunchRecoveryError(
            message: "boot session UUID is available only on macOS"
        )
        #endif
    }

    static func systemObservation(
        executablePath: String
    ) throws -> SystemObservation {
        let bootBefore = try currentBootSessionUUID()
        var census = exactExecutableCensus(
            executablePath: executablePath
        )
        let bootAfter = try currentBootSessionUUID()
        guard bootBefore == bootAfter else {
            census = .incomplete(
                candidates: census.candidates,
                reason:
                    "boot session changed during process census"
            )
            return SystemObservation(
                bootSessionUUID: bootAfter,
                census: census
            )
        }
        return SystemObservation(
            bootSessionUUID: bootBefore,
            census: census
        )
    }

    static func exactExecutableCensus(
        executablePath: String
    ) -> Census {
        if let exactExecutableCensusOverrideForTesting {
            return exactExecutableCensusOverrideForTesting(
                executablePath
            )
        }
        #if canImport(Darwin)
        let expected = PlayCoverRuntimeClient.canonicalPath(
            executablePath
        )
        let pidStride = MemoryLayout<pid_t>.stride
        let processListKind = UInt32(PROC_UID_ONLY)
        let processListTypeInfo = UInt32(geteuid())
        let requiredBytes = Darwin.proc_listpids(
            processListKind,
            processListTypeInfo,
            nil,
            0
        )
        guard requiredBytes > 0,
              Int(requiredBytes) % pidStride == 0 else {
            return .incomplete(
                candidates: [],
                reason:
                    "proc_listpids could not size the census: "
                    + "errno \(errno)"
            )
        }
        var capacity = max(
            Int(requiredBytes) / pidStride + 256,
            1_024
        )

        var pids: [pid_t] = []
        var censusComplete = false
        for _ in 0..<8 {
            var buffer = [pid_t](
                repeating: 0,
                count: capacity
            )
            let byteCapacity = buffer.count * pidStride
            guard let byteCapacity32 =
                    Int32(exactly: byteCapacity) else {
                return .incomplete(
                    candidates: [],
                    reason: "process census buffer exceeded Int32"
                )
            }
            let byteCount = buffer.withUnsafeMutableBytes {
                Darwin.proc_listpids(
                    processListKind,
                    processListTypeInfo,
                    $0.baseAddress,
                    byteCapacity32
                )
            }
            guard byteCount > 0,
                  Int(byteCount) <= byteCapacity,
                  Int(byteCount) % pidStride == 0 else {
                return .incomplete(
                    candidates: [],
                    reason:
                        "proc_listpids returned an invalid census: "
                        + "errno \(errno)"
                )
            }
            if Int(byteCount) < byteCapacity {
                pids = Array(
                    buffer.prefix(
                        Int(byteCount) / pidStride
                    )
                )
                censusComplete = true
                break
            }
            capacity = min(capacity * 2, 1_048_576)
        }
        guard censusComplete else {
            return .incomplete(
                candidates: [],
                reason:
                    "process table changed faster than it could be "
                    + "enumerated"
            )
        }

        var candidates: [Candidate] = []
        var unreadable: [Int32] = []
        for pid in Set(pids) where pid > 0 {
            switch stableExactCandidate(
                pid: pid,
                expectedExecutablePath: expected
            ) {
            case .candidate(let candidate):
                if let candidate {
                    candidates.append(candidate)
                }
            case .unverifiable:
                unreadable.append(pid)
            }
        }
        candidates.sort { $0.pid < $1.pid }
        guard unreadable.isEmpty else {
            let sample = unreadable.sorted().prefix(8)
                .map(String.init)
                .joined(separator: ",")
            return .incomplete(
                candidates: candidates,
                reason:
                    "could not inspect \(unreadable.count) live "
                    + "process executable path(s)"
                    + (sample.isEmpty ? "" : " (pid \(sample))")
            )
        }
        return .complete(candidates)
        #else
        return .incomplete(
            candidates: [],
            reason: "process census is available only on macOS"
        )
        #endif
    }

    static func ownedProcessState(
        pid: Int32
    ) -> OwnedProcessState {
        if let ownedProcessStateOverrideForTesting {
            return ownedProcessStateOverrideForTesting(pid)
        }
        switch PlayCoverSessionService.processState(pid) {
        case .running(let executablePath):
            return .running(
                executablePath: executablePath,
                processBirthMicroseconds:
                    PlayCoverService
                        .processStartTimeMicroseconds(for: pid)
            )
        case .missing:
            return .missing
        case .unverifiable(let errorNumber):
            return .unverifiable(errno: errorNumber)
        }
    }

    static func authenticateCandidateOwner(
        evidence: Evidence,
        census: Census,
        foreignSessions: [ForeignSession] = []
    ) -> Result<Owner?, PlayCoverPendingLaunchRecoveryError> {
        var authenticated: [Owner] = []
        for candidate in census.candidates {
            switch candidateStillMatches(
                candidate,
                evidence: evidence
            ) {
            case .success(false):
                continue
            case .success(true):
                break
            case .failure(let error):
                return .failure(error)
            }
            let accepted: Bool
            var ownAuthenticationFailure: Error?
            do {
                if let candidateAuthenticationOverrideForTesting {
                    accepted = try
                        candidateAuthenticationOverrideForTesting(
                            candidate,
                            evidence
                        )
                } else {
                    accepted = try authenticateRuntime(
                        candidate: candidate,
                        sessionID: evidence.sessionID,
                        runtimeSocketPath:
                            evidence.runtimeSocketPath,
                        evidence: evidence
                    )
                }
            } catch {
                ownAuthenticationFailure = error
                accepted = false
            }
            if accepted {
                switch candidateStillMatches(
                    candidate,
                    evidence: evidence
                ) {
                case .success(false):
                    continue
                case .success(true):
                    break
                case .failure(let error):
                    return .failure(error)
                }
                guard let processBirth =
                        candidate.processBirthMicroseconds else {
                    return .failure(
                        PlayCoverPendingLaunchRecoveryError(
                            message:
                                "authenticated pid \(candidate.pid) has "
                                + "no stable process birth token"
                        )
                    )
                }
                authenticated.append(
                    Owner(
                        pid: candidate.pid,
                        processBirthMicroseconds: processBirth,
                        source: .authenticatedRuntime
                    )
                )
                continue
            }

            var foreignClaims = 0
            var foreignFailures: [String] = []
            for foreign in foreignSessions {
                do {
                    guard try authenticateRuntime(
                        candidate: candidate,
                        sessionID: foreign.sessionID,
                        runtimeSocketPath:
                            foreign.runtimeSocketPath,
                        evidence: evidence
                    ) else {
                        foreignFailures.append(
                            "session \(foreign.sessionID): incomplete "
                                + "Runtime identity"
                        )
                        continue
                    }
                    foreignClaims += 1
                } catch {
                    // A peer-PID mismatch proves that this authenticated
                    // socket belongs to another process. Every other
                    // transport, credential, executable, or protocol failure
                    // leaves ownership unverifiable and must fail closed.
                    if case PlayCoverRuntimeClientError
                        .peerPIDMismatch = error {
                        continue
                    }
                    foreignFailures.append(
                        "session \(foreign.sessionID): \(error)"
                    )
                }
            }
            guard foreignClaims <= 1 else {
                return .failure(
                    PlayCoverPendingLaunchRecoveryError(
                        message:
                            "candidate pid \(candidate.pid) was claimed "
                                + "by multiple foreign Home sessions"
                    )
                )
            }
            guard foreignClaims == 1 else {
                let ownFailureSuffix = ownAuthenticationFailure.map {
                    "; pending-session authentication failed: \($0)"
                } ?? ""
                let foreignFailureSuffix =
                    foreignFailures.isEmpty
                    ? ""
                    : "; foreign-session failures: "
                        + foreignFailures.joined(separator: " | ")
                return .failure(
                    PlayCoverPendingLaunchRecoveryError(
                        message:
                            "candidate pid \(candidate.pid) could not be "
                                + "authenticated as this pending session or "
                                + "exactly one durable foreign Home session"
                                + ownFailureSuffix
                                + foreignFailureSuffix
                    )
                )
            }
            switch candidateStillMatches(
                candidate,
                evidence: evidence
            ) {
            case .success(false):
                continue
            case .success(true):
                break
            case .failure(let error):
                return .failure(error)
            }
        }
        guard authenticated.count <= 1 else {
            return .failure(
                PlayCoverPendingLaunchRecoveryError(
                    message:
                        "multiple exact processes authenticated the "
                        + "same pending launch session"
                )
            )
        }
        return .success(authenticated.first)
    }

    private enum ExecutablePathCensusResult {
        case path(String)
        case exited
        case unverifiable
    }

    private enum StableCandidateResult {
        case candidate(Candidate?)
        case unverifiable
    }

    private static func stableExactCandidate(
        pid: Int32,
        expectedExecutablePath: String
    ) -> StableCandidateResult {
        switch executablePathForCensus(pid) {
        case .exited:
            return .candidate(nil)
        case .unverifiable:
            return stableOpaqueNonCandidate(
                pid: pid,
                expectedExecutablePath: expectedExecutablePath
            )
        case .path(let firstPath):
            guard PlayCoverRuntimeClient.canonicalPath(firstPath)
                    == expectedExecutablePath else {
                return .candidate(nil)
            }
        }
        guard let firstBirth =
                PlayCoverService.processStartTimeMicroseconds(
                    for: pid
                ) else {
            return .unverifiable
        }
        switch executablePathForCensus(pid) {
        case .exited:
            return .candidate(nil)
        case .unverifiable:
            return .unverifiable
        case .path(let secondPath):
            guard PlayCoverRuntimeClient.canonicalPath(secondPath)
                    == expectedExecutablePath,
                  let secondBirth =
                    PlayCoverService.processStartTimeMicroseconds(
                        for: pid
                    ),
                  firstBirth == secondBirth else {
                return .unverifiable
            }
        }
        return .candidate(
            Candidate(
                pid: pid,
                processBirthMicroseconds: firstBirth
            )
        )
    }

    private struct OpaqueProcessInfo: Equatable {
        let status: UInt32
        let command: String
        let processBirthMicroseconds: UInt64
    }

    private enum OpaqueProcessInfoResult {
        case info(OpaqueProcessInfo)
        case exited
        case unverifiable
    }

    private static func stableOpaqueNonCandidate(
        pid: Int32,
        expectedExecutablePath: String
    ) -> StableCandidateResult {
        #if canImport(Darwin)
        let first = opaqueProcessInfo(pid)
        switch first {
        case .exited:
            return .candidate(nil)
        case .unverifiable:
            return .unverifiable
        case .info(let info):
            guard opaqueProcessCanBeExcluded(
                status: info.status,
                command: info.command,
                expectedExecutablePath: expectedExecutablePath
            ) else {
                return .unverifiable
            }
        }

        let second = opaqueProcessInfo(pid)
        switch second {
        case .exited:
            return .candidate(nil)
        case .unverifiable:
            return .unverifiable
        case .info(let info):
            guard case .info(let firstInfo) = first,
                  info.processBirthMicroseconds
                    == firstInfo.processBirthMicroseconds,
                  opaqueProcessCanBeExcluded(
                    status: info.status,
                    command: info.command,
                    expectedExecutablePath: expectedExecutablePath
                  ) else {
                return .unverifiable
            }
            return .candidate(nil)
        }
        #else
        return .unverifiable
        #endif
    }

    private static func opaqueProcessInfo(
        _ pid: Int32
    ) -> OpaqueProcessInfoResult {
        #if canImport(Darwin)
        var query = [
            Int32(CTL_KERN),
            Int32(KERN_PROC),
            Int32(KERN_PROC_PID),
            pid,
        ]
        var info = kinfo_proc()
        var byteCount = MemoryLayout<kinfo_proc>.size
        errno = 0
        let result = query.withUnsafeMutableBufferPointer {
            Darwin.sysctl(
                $0.baseAddress,
                u_int($0.count),
                &info,
                &byteCount,
                nil,
                0
            )
        }
        if result != 0 {
            return errno == ESRCH || errno == ENOENT
                ? .exited
                : .unverifiable
        }
        guard byteCount == MemoryLayout<kinfo_proc>.size else {
            return byteCount == 0 ? .exited : .unverifiable
        }
        guard info.kp_proc.p_pid == pid,
              info.kp_eproc.e_ucred.cr_uid == geteuid() else {
            return .unverifiable
        }
        let seconds = UInt64(info.kp_proc.p_starttime.tv_sec)
        let microseconds = UInt64(
            info.kp_proc.p_starttime.tv_usec
        )
        guard microseconds < 1_000_000,
              seconds <=
                (UInt64.max - microseconds) / 1_000_000 else {
            return .unverifiable
        }
        let command = withUnsafeBytes(
            of: info.kp_proc.p_comm
        ) { rawBuffer -> String in
            let bytes = rawBuffer.prefix {
                $0 != 0
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return .info(
            OpaqueProcessInfo(
                status: UInt32(info.kp_proc.p_stat),
                command: command,
                processBirthMicroseconds:
                    seconds * 1_000_000 + microseconds
            )
        )
        #else
        return .unverifiable
        #endif
    }

    static func opaqueProcessCanBeExcluded(
        status: UInt32,
        command: String,
        expectedExecutablePath: String
    ) -> Bool {
        #if canImport(Darwin)
        if status == UInt32(SZOMB) {
            return true
        }
        #endif
        guard !command.isEmpty else {
            return false
        }
        let expected = URL(
            fileURLWithPath: expectedExecutablePath
        ).lastPathComponent
        guard command != expected else {
            return false
        }
        let commandBytes = Array(command.utf8)
        let expectedBytes = Array(expected.utf8)
        if expectedBytes.starts(with: commandBytes) {
            return false
        }
        return true
    }

    private static func executablePathForCensus(
        _ pid: Int32
    ) -> ExecutablePathCensusResult {
        #if canImport(Darwin)
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        errno = 0
        let count = buffer.withUnsafeMutableBufferPointer {
            Darwin.proc_pidpath(
                pid,
                $0.baseAddress,
                UInt32($0.count)
            )
        }
        if count > 0 {
            return .path(String(cString: buffer))
        }
        let probe = Darwin.kill(pid, 0)
        let probeError = errno
        if probe != 0, probeError == ESRCH {
            return .exited
        }
        return .unverifiable
        #else
        return .unverifiable
        #endif
    }

    private static func authenticateRuntime(
        candidate: Candidate,
        sessionID: String,
        runtimeSocketPath: String,
        evidence: Evidence
    ) throws -> Bool {
        let client = PlayCoverRuntimeClient(
            socketPath: runtimeSocketPath,
            sessionID: sessionID,
            expectedPID: candidate.pid,
            expectedBundleIdentifier:
                evidence.bundleIdentifier,
            expectedExecutablePath: evidence.executablePath,
            timeoutSeconds: 0.25
        )
        let ping = try client.ping()
        // Recovery has only process-table/executable evidence for a
        // candidate. Unlike the live launch path, it cannot rely on the
        // callback's exact facade bundle URL to authorize the legacy bare
        // pong -> hello fallback. Require identified ping here.
        return ping.hasCompleteIdentity
    }

    private static func candidateStillMatches(
        _ candidate: Candidate,
        evidence: Evidence
    ) -> Result<Bool, PlayCoverPendingLaunchRecoveryError> {
        switch ownedProcessState(pid: candidate.pid) {
        case .missing:
            return .success(false)
        case .unverifiable(let errorNumber):
            return .failure(
                PlayCoverPendingLaunchRecoveryError(
                    message:
                        "cannot revalidate candidate pid "
                        + "\(candidate.pid): errno \(errorNumber)"
                )
            )
        case .running(
            let executablePath,
            let processBirth
        ):
            guard PlayCoverRuntimeClient.canonicalPath(
                executablePath
            ) == PlayCoverRuntimeClient.canonicalPath(
                evidence.executablePath
            ) else {
                return .success(false)
            }
            guard let expectedBirth =
                    candidate.processBirthMicroseconds,
                  let processBirth else {
                return .failure(
                    PlayCoverPendingLaunchRecoveryError(
                        message:
                            "candidate pid \(candidate.pid) has no "
                            + "stable process birth token"
                    )
                )
            }
            return .success(processBirth == expectedBirth)
        }
    }

    private static func decideOwnedProcess(
        owner: Owner,
        expectedExecutablePath: String,
        state: OwnedProcessState
    ) -> Decision {
        switch state {
        case .missing:
            return .safeCleanup(.ownedProcessExited)
        case .unverifiable(let errorNumber):
            return .unresolved(
                "cannot inspect owned pid \(owner.pid): errno "
                    + "\(errorNumber)"
            )
        case .running(
            let executablePath,
            let processBirth
        ):
            guard PlayCoverRuntimeClient.canonicalPath(
                executablePath
            ) == PlayCoverRuntimeClient.canonicalPath(
                expectedExecutablePath
            ) else {
                return .safeCleanup(.ownedPIDReused)
            }
            guard let processBirth else {
                return .unresolved(
                    "live owned pid \(owner.pid) has no stable "
                        + "process birth token"
                )
            }
            guard processBirth
                    == owner.processBirthMicroseconds else {
                return .safeCleanup(.ownedPIDReused)
            }
            return .ownedProcessLive(owner)
        }
    }

    private static func validateBootSessionUUID(
        _ value: String
    ) throws -> String {
        guard let uuid = UUID(
            uuidString: value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) else {
            throw PlayCoverPendingLaunchRecoveryError(
                message: "kern.bootsessionuuid is not a UUID"
            )
        }
        return uuid.uuidString.lowercased()
    }

    private static func canonicalBootSessionUUID(
        _ value: String
    ) -> String {
        UUID(uuidString: value)?.uuidString.lowercased()
            ?? value.lowercased()
    }

    private static func censusUnresolvedReason(
        prefix: String,
        census: Census
    ) -> String {
        switch census {
        case .complete(let candidates):
            return prefix
                + "; exact process count is \(candidates.count)"
        case .incomplete(let candidates, let reason):
            return prefix
                + "; census is incomplete (\(reason)); "
                + "known exact process count is "
                + "\(candidates.count)"
        }
    }
}
