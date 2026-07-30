import XCTest
@testable import IOSUseCLI

final class PlayCoverPendingLaunchRecoveryTests: XCTestCase {
    private let bootA =
        "11111111-1111-4111-8111-111111111111"
    private let bootB =
        "22222222-2222-4222-8222-222222222222"
    private let executablePath =
        "/tmp/pending/Example.app/Example"

    override func tearDown() {
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = nil
        super.tearDown()
    }

    func testPreSubmissionIntentIsSafeToClean() {
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: nil
                ),
                currentBoot: bootA,
                census: .complete([])
            ),
            .safeCleanup(.neverSubmitted)
        )
    }

    func testSameBootArmedLaunchStaysUnresolvedWithEmptyCensus() {
        let decision = decide(
            evidence: makeEvidence(
                submissionBootSessionUUID: bootA
            ),
            currentBoot: bootA,
            census: .complete([])
        )
        guard case .unresolved(let reason) = decision else {
            return XCTFail("armed current-boot launch was cleaned")
        }
        XCTAssertTrue(reason.contains("current boot"))
    }

    func testTerminalCallbackAndCompleteEmptyCensusIsSafe() {
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA,
                    terminalCallbackRecorded: true
                ),
                currentBoot: bootA,
                census: .complete([])
            ),
            .safeCleanup(.terminalCallbackAndEmptyCensus)
        )
    }

    func testTerminalCallbackAndIncompleteCensusStaysUnresolved() {
        let decision = decide(
            evidence: makeEvidence(
                submissionBootSessionUUID: bootA,
                terminalCallbackRecorded: true
            ),
            currentBoot: bootA,
            census: .incomplete(
                candidates: [],
                reason: "same-uid pid path unavailable"
            )
        )
        guard case .unresolved(let reason) = decision else {
            return XCTFail("incomplete census authorized cleanup")
        }
        XCTAssertTrue(reason.contains("incomplete"))
    }

    #if canImport(Darwin)
    func testExactExecutableCensusIgnoresProvablyUnrelatedProcesses() {
        let absentExecutable =
            "/tmp/ios-use-absent-\(UUID().uuidString)/App"
        switch PlayCoverPendingLaunchRecovery.exactExecutableCensus(
            executablePath: absentExecutable
        ) {
        case .complete(let candidates):
            XCTAssertTrue(candidates.isEmpty)
        case .incomplete(_, let reason):
            XCTFail(
                "same-UID census was blocked by unrelated processes: "
                    + reason
            )
        }
    }

    func testOpaqueProcessFilterFailsClosedForPossibleTargetNames() {
        let expected =
            "/tmp/pending/IOSUsePlayFixture.app/IOSUsePlayFixture"
        XCTAssertTrue(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SRUN),
                    command: "node_repl",
                    expectedExecutablePath: expected
                )
        )
        XCTAssertFalse(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SRUN),
                    command: "IOSUsePlayFixture",
                    expectedExecutablePath: expected
                )
        )
        XCTAssertFalse(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SRUN),
                    command: "",
                    expectedExecutablePath: expected
                )
        )
        XCTAssertFalse(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SRUN),
                    command: "IOSUsePlayFixtu",
                    expectedExecutablePath: expected
                )
        )
        XCTAssertFalse(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SRUN),
                    command: "IOSUsePlayFixtur",
                    expectedExecutablePath: expected
                )
        )
        XCTAssertTrue(
            PlayCoverPendingLaunchRecovery
                .opaqueProcessCanBeExcluded(
                    status: UInt32(SZOMB),
                    command: "IOSUsePlayFixture",
                    expectedExecutablePath: expected
                )
        )
    }
    #endif

    func testNewBootAndCompleteEmptyCensusIsSafe() {
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA
                ),
                currentBoot: bootB,
                census: .complete([])
            ),
            .safeCleanup(.newBootAndEmptyCensus)
        )
    }

    func testNewBootIgnoresSameExecutableProcessFromCurrentBoot() {
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA
                ),
                currentBoot: bootB,
                census: .complete([
                    .init(
                        pid: 42,
                        processBirthMicroseconds: 100
                    ),
                ])
            ),
            .safeCleanup(.newBootAndEmptyCensus)
        )
    }

    func testOwnedMissingProcessIsSafeToClean() {
        let owner = makeOwner()
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA,
                    owner: owner
                ),
                currentBoot: bootA,
                census: .complete([]),
                ownedProcessState: .missing
            ),
            .safeCleanup(.ownedProcessExited)
        )
    }

    func testOwnedDifferentExecutableProvesPIDReuse() {
        let owner = makeOwner()
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA,
                    owner: owner
                ),
                currentBoot: bootA,
                census: .complete([]),
                ownedProcessState: .running(
                    executablePath: "/tmp/Other",
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds
                )
            ),
            .safeCleanup(.ownedPIDReused)
        )
    }

    func testOwnedSameExecutableDifferentBirthProvesPIDReuse() {
        let owner = makeOwner()
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA,
                    owner: owner
                ),
                currentBoot: bootA,
                census: .complete([]),
                ownedProcessState: .running(
                    executablePath: executablePath,
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds + 1
                )
            ),
            .safeCleanup(.ownedPIDReused)
        )
    }

    func testExactOwnedLiveProcessIsReturnedForTermination() {
        let owner = makeOwner()
        XCTAssertEqual(
            decide(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA,
                    owner: owner
                ),
                currentBoot: bootA,
                census: .complete([]),
                ownedProcessState: .running(
                    executablePath: executablePath,
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds
                )
            ),
            .ownedProcessLive(owner)
        )
    }

    func testOwnedUnverifiableProcessStaysUnresolved() {
        let owner = makeOwner()
        let decision = decide(
            evidence: makeEvidence(
                submissionBootSessionUUID: bootA,
                owner: owner
            ),
            currentBoot: bootA,
            census: .complete([]),
            ownedProcessState: .unverifiable(errno: EPERM)
        )
        guard case .unresolved(let reason) = decision else {
            return XCTFail("unverifiable owned process was cleaned")
        }
        XCTAssertTrue(reason.contains("errno \(EPERM)"))
    }

    func testCandidateRuntimeAuthenticationProducesDurableOwner() {
        let candidate =
            PlayCoverPendingLaunchRecovery.Candidate(
                pid: 42,
                processBirthMicroseconds: 123
            )
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { pid in
                XCTAssertEqual(pid, candidate.pid)
                return .running(
                    executablePath: self.executablePath,
                    processBirthMicroseconds:
                        candidate.processBirthMicroseconds
                )
            }
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = {
                actual,
                evidence in
                XCTAssertEqual(actual, candidate)
                XCTAssertEqual(
                    evidence.sessionID,
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                )
                return true
            }

        let result = PlayCoverPendingLaunchRecovery
            .authenticateCandidateOwner(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA
                ),
                census: .complete([candidate])
            )
        XCTAssertEqual(
            try? result.get(),
            .init(
                pid: candidate.pid,
                processBirthMicroseconds: 123,
                source: .authenticatedRuntime
            )
        )
    }

    func testAuthenticatedCandidateWithoutBirthFailsClosed() {
        let candidate =
            PlayCoverPendingLaunchRecovery.Candidate(
                pid: 42,
                processBirthMicroseconds: nil
            )
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { _ in
                .running(
                    executablePath: self.executablePath,
                    processBirthMicroseconds: nil
                )
            }
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = {
                _,
                _ in true
            }

        let result = PlayCoverPendingLaunchRecovery
            .authenticateCandidateOwner(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA
                ),
                census: .complete([candidate])
            )
        guard case .failure(let error) = result else {
            return XCTFail("birthless candidate became an owner")
        }
        XCTAssertTrue(error.message.contains("birth token"))
    }

    func testMultipleAuthenticatedCandidatesFailClosed() {
        let candidates = [
            PlayCoverPendingLaunchRecovery.Candidate(
                pid: 42,
                processBirthMicroseconds: 123
            ),
            PlayCoverPendingLaunchRecovery.Candidate(
                pid: 43,
                processBirthMicroseconds: 124
            ),
        ]
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { pid in
                .running(
                    executablePath: self.executablePath,
                    processBirthMicroseconds:
                        pid == 42 ? 123 : 124
                )
            }
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = {
                _,
                _ in true
            }

        let result = PlayCoverPendingLaunchRecovery
            .authenticateCandidateOwner(
                evidence: makeEvidence(
                    submissionBootSessionUUID: bootA
                ),
                census: .complete(candidates)
            )
        guard case .failure(let error) = result else {
            return XCTFail("ambiguous candidates became an owner")
        }
        XCTAssertTrue(error.message.contains("multiple exact"))
    }

    func testBootChangeDuringCensusMakesObservationIncomplete()
        throws
    {
        var bootReadCount = 0
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = {
                bootReadCount += 1
                return bootReadCount == 1
                    ? self.bootA
                    : self.bootB
            }
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = {
                XCTAssertEqual($0, self.executablePath)
                return .complete([])
            }

        let observation = try PlayCoverPendingLaunchRecovery
            .systemObservation(
                executablePath: executablePath
            )
        XCTAssertEqual(
            observation.bootSessionUUID,
            bootB.lowercased()
        )
        guard case .incomplete(
            let candidates,
            let reason
        ) = observation.census else {
            return XCTFail("boot-raced census remained complete")
        }
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(reason.contains("boot session changed"))
    }

    func testBootSessionUUIDOverrideIsValidatedAndNormalized()
        throws
    {
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = {
                "  \(self.bootA.uppercased())\n"
            }
        XCTAssertEqual(
            try PlayCoverPendingLaunchRecovery
                .currentBootSessionUUID(),
            bootA.lowercased()
        )
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = {
                "not-a-uuid"
            }
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchRecovery
                .currentBootSessionUUID()
        )
    }

    private func decide(
        evidence: PlayCoverPendingLaunchRecovery.Evidence,
        currentBoot: String,
        census: PlayCoverPendingLaunchRecovery.Census,
        ownedProcessState:
            PlayCoverPendingLaunchRecovery.OwnedProcessState? = nil,
        authenticatedOwner:
            PlayCoverPendingLaunchRecovery.Owner? = nil
    ) -> PlayCoverPendingLaunchRecovery.Decision {
        PlayCoverPendingLaunchRecovery.decide(
            evidence: evidence,
            currentBootSessionUUID: currentBoot,
            census: census,
            ownedProcessState: ownedProcessState,
            authenticatedOwner: authenticatedOwner
        )
    }

    private func makeEvidence(
        submissionBootSessionUUID: String?,
        terminalCallbackRecorded: Bool = false,
        owner: PlayCoverPendingLaunchRecovery.Owner? = nil
    ) -> PlayCoverPendingLaunchRecovery.Evidence {
        .init(
            sessionID:
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            runtimeSocketPath: "/tmp/pending.sock",
            bundleIdentifier: "com.example.pending",
            executablePath: executablePath,
            submissionBootSessionUUID:
                submissionBootSessionUUID,
            terminalCallbackRecorded:
                terminalCallbackRecorded,
            owner: owner
        )
    }

    private func makeOwner()
        -> PlayCoverPendingLaunchRecovery.Owner
    {
        .init(
            pid: 42,
            processBirthMicroseconds: 123,
            source: .workspaceCallback
        )
    }
}
