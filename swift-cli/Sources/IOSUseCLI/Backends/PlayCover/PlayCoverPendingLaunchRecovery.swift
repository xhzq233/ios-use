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
        "PlayCover pending launch recovery failed: \(message)"
    }
}

/// The recovery authority for a submitted PlayCover launch.
///
/// This type deliberately does not infer safety from age, a missing Runtime
/// socket, or an empty AppKit query. `Decision` is derived only from durable
/// submission evidence, an exact owned process identity, the current boot,
/// and a complete process-table census.
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
        authenticatedOwner: Owner?
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
            if census.provesEmpty {
                return .safeCleanup(.newBootAndEmptyCensus)
            }
            return .unresolved(
                censusUnresolvedReason(
                    prefix:
                        "boot changed, but an empty exact-executable "
                        + "census was not proven",
                    census: census
                )
            )
        }

        if evidence.terminalCallbackRecorded {
            if census.provesEmpty {
                return .safeCleanup(
                    .terminalCallbackAndEmptyCensus
                )
            }
            return .unresolved(
                censusUnresolvedReason(
                    prefix:
                        "terminal callback is durable, but an empty "
                        + "exact-executable census was not proven",
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
        let processListKind = UInt32(PROC_ALL_PIDS)
        let requiredBytes = Darwin.proc_listpids(
            processListKind,
            0,
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
                    0,
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
            switch processUserForCensus(pid) {
            case .otherUser:
                continue
            case .exited:
                continue
            case .unverifiable:
                unreadable.append(pid)
                continue
            case .currentUser:
                break
            }
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
        census: Census
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
                        evidence: evidence
                    )
                }
            } catch {
                continue
            }
            guard accepted else {
                continue
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

    private enum ProcessUserCensusResult {
        case currentUser
        case otherUser
        case exited
        case unverifiable
    }

    private static func processUserForCensus(
        _ pid: Int32
    ) -> ProcessUserCensusResult {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let expectedSize = Int32(
            MemoryLayout<proc_bsdinfo>.size
        )
        let actualSize = Darwin.proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        if actualSize == expectedSize {
            return info.pbi_uid == geteuid()
                ? .currentUser
                : .otherUser
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
            return .unverifiable
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
        evidence: Evidence
    ) throws -> Bool {
        let client = PlayCoverRuntimeClient(
            socketPath: evidence.runtimeSocketPath,
            sessionID: evidence.sessionID,
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
