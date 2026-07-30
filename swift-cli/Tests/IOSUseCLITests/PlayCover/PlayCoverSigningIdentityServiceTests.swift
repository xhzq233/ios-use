import Foundation
import Security
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverSigningIdentityServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var initializationLockRoot: URL!
    private var initializationLockURL: URL {
        initializationLockRoot.appendingPathComponent(
            "mac-signer.lock"
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        initializationLockRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "ios-use-signing-service-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: initializationLockRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let initializationLockRoot {
            try? FileManager.default.removeItem(
                at: initializationLockRoot
            )
        }
        initializationLockRoot = nil
        try super.tearDownWithError()
    }

    func testACLMatcherAllowsExactCodesignTrustedApplicationData() {
        let required = Data([0x01, 0x02, 0x03])

        XCTAssertTrue(
            PlayCoverSigningACLMatcher
                .containsRequiredTrustedApplication(
                    required,
                    candidates: [
                        Data([0x09]),
                        required,
                    ]
                )
        )
    }

    func testACLMatcherDeniesMissingCodesignTrustedApplicationData() {
        let required = Data([0x01, 0x02, 0x03])

        XCTAssertFalse(
            PlayCoverSigningACLMatcher
                .containsRequiredTrustedApplication(
                    required,
                    candidates: [
                        Data([0x01, 0x02]),
                        Data([0x01, 0x02, 0x04]),
                    ]
                )
        )
        XCTAssertFalse(
            PlayCoverSigningACLMatcher
                .containsRequiredTrustedApplication(
                    required,
                    candidates: []
                )
        )
    }

    func testResolveWithoutBindingIsMissingAndNeverCreatesIdentity() {
        let backend = FakeSigningIdentityBackend()
        let service = makeService(backend)

        let result = service.resolve()

        XCTAssertEqual(result.health, .missing)
        XCTAssertNil(result.evidence)
        XCTAssertEqual(backend.createCount, 0)
    }

    func testErrorsUseMacBackendUserAndMachineNamespaces() {
        let healthCases: [PlayCoverSigningIdentityHealth] = [
            .healthy,
            .missing,
            .replaced,
            .expired,
            .trustRequired,
            .inaccessible,
            .unavailable,
        ]
        let cases: [(PlayCoverSigningIdentityServiceError, String)] = [
            (
                .identityCreationUnavailable,
                "mac_signing_identity_creation_unavailable"
            ),
            (
                .invalidCreatedIdentity,
                "mac_signing_identity_invalid"
            ),
            (
                .bindingUnavailable,
                "mac_signing_identity_binding_unavailable"
            ),
            (
                .trustConfigurationFailed(errSecAuthFailed),
                "mac_signing_identity_trust_required"
            ),
            (
                .signingProbeFailed("denied"),
                "mac_signing_identity_inaccessible"
            ),
        ] + healthCases.map {
            (
                .unhealthy($0),
                "mac_signing_identity_\($0.rawValue)"
            )
        }

        for (error, expectedCode) in cases {
            XCTAssertEqual(error.machineError.code, expectedCode)
            XCTAssertEqual(
                error.machineError.phase,
                "mac_signing_identity"
            )
            XCTAssertTrue(
                error.description.contains("Mac backend"),
                error.description
            )
            XCTAssertFalse(
                error.description.contains("PlayCover"),
                error.description
            )
        }
    }

    func testInitializeBindsExactImmutableEvidence() throws {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(seed: "A")
        backend.identities = [identity]
        backend.identitiesToCreate = [identity]
        let service = makeService(backend)

        let result = try service.initializeIfNeeded()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(
            result.evidence,
            evidence(identity, health: .healthy)
        )
        XCTAssertEqual(backend.binding?.certificateSHA256, hex("A", 64))
        XCTAssertEqual(backend.binding?.codesignSelector, hex("A", 40))
        XCTAssertEqual(backend.createCount, 1)
    }

    func testExplicitConfigurationTrustsAndProbesOneCreatedIdentity()
        throws
    {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(
            seed: "B",
            trustedForCodeSigning: false
        )
        backend.identitiesToCreate = [identity]
        let service = makeService(backend)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: initializationLockURL.path
            )
        )
        let result = try service.initializeForConfiguration()

        XCTAssertEqual(result.policy.health, .healthy)
        XCTAssertEqual(result.certificateSHA256, identity.certificateSHA256)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.configureTrustCount, 1)
        XCTAssertEqual(backend.probeCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: initializationLockURL.path
            )
        )
    }

    func testCancelledTrustRetryReusesSameBoundIdentity() throws {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(
            seed: "C",
            trustedForCodeSigning: false
        )
        backend.identitiesToCreate = [identity]
        backend.trustFailuresRemaining = 1
        let service = makeService(backend)

        XCTAssertThrowsError(
            try service.initializeForConfiguration()
        )
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(
            backend.binding?.certificateSHA256,
            identity.certificateSHA256
        )

        let result = try service.initializeForConfiguration()

        XCTAssertEqual(result.certificateSHA256, identity.certificateSHA256)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.configureTrustCount, 2)
        XCTAssertEqual(backend.probeCount, 1)
    }

    func testTrustBackendUnavailableMapsToUnavailableHealth() {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(
            seed: "D",
            trustedForCodeSigning: false
        )
        backend.binding = binding(identity)
        backend.identities = [identity]
        backend.failure = .trustUnavailable

        XCTAssertThrowsError(
            try makeService(backend).initializeForConfiguration()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .unhealthy(.unavailable)
            )
        }
        XCTAssertEqual(backend.configureTrustCount, 1)
        XCTAssertEqual(backend.probeCount, 0)
    }

    func testConfigurationRepairsMissingDeterministicCertificate()
        throws
    {
        let backend = FakeSigningIdentityBackend()
        let expected = makeIdentity(seed: "5")
        let originalBinding = binding(expected)
        backend.binding = originalBinding
        backend.identitiesToCreate = [expected]

        let result = try makeService(backend)
            .initializeForConfiguration()

        XCTAssertEqual(result, evidence(expected))
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.binding, originalBinding)
        XCTAssertEqual(backend.configureTrustCount, 0)
        XCTAssertEqual(backend.probeCount, 1)
    }

    func testConfigurationRepairsSameKeyReplacementWithoutRotation()
        throws
    {
        let backend = FakeSigningIdentityBackend()
        let expected = makeIdentity(seed: "6")
        let replacement = PlayCoverSigningIdentitySnapshot(
            publicKeySPKISHA256: expected.publicKeySPKISHA256,
            certificateSHA256: hex("7", 64),
            codesignSelector: hex("7", 40),
            notBefore: expected.notBefore,
            notAfter: expected.notAfter
        )
        let originalBinding = binding(expected)
        backend.binding = originalBinding
        backend.identities = [replacement]
        backend.identitiesToCreate = [expected]

        let result = try makeService(backend)
            .initializeForConfiguration()

        XCTAssertEqual(result, evidence(expected))
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.binding, originalBinding)
        XCTAssertEqual(backend.identities, [replacement, expected])
    }

    func testConfigurationRejectsNonIdenticalRepairWithoutReplacingBinding() {
        let expected = makeIdentity(seed: "8")
        let originalBinding = binding(expected)
        let mismatches = [
            PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256: hex("A", 64),
                certificateSHA256: expected.certificateSHA256,
                codesignSelector: expected.codesignSelector,
                notBefore: expected.notBefore,
                notAfter: expected.notAfter
            ),
            PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256: expected.publicKeySPKISHA256,
                certificateSHA256: hex("B", 64),
                codesignSelector: expected.codesignSelector,
                notBefore: expected.notBefore,
                notAfter: expected.notAfter
            ),
            PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256: expected.publicKeySPKISHA256,
                certificateSHA256: expected.certificateSHA256,
                codesignSelector: hex("C", 40),
                notBefore: expected.notBefore,
                notAfter: expected.notAfter
            ),
            PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256: expected.publicKeySPKISHA256,
                certificateSHA256: expected.certificateSHA256,
                codesignSelector: expected.codesignSelector,
                notBefore: expected.notBefore.addingTimeInterval(1),
                notAfter: expected.notAfter
            ),
        ]

        for mismatch in mismatches {
            let backend = FakeSigningIdentityBackend()
            backend.binding = originalBinding
            backend.identitiesToCreate = [mismatch]

            XCTAssertThrowsError(
                try makeService(backend)
                    .initializeForConfiguration()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverSigningIdentityServiceError,
                    .invalidCreatedIdentity
                )
            }
            XCTAssertEqual(backend.createCount, 1)
            XCTAssertEqual(backend.binding, originalBinding)
            XCTAssertEqual(backend.configureTrustCount, 0)
            XCTAssertEqual(backend.probeCount, 0)
        }
    }

    func testOrdinaryResolutionNeverRepairsMissingBoundIdentity() {
        let backend = FakeSigningIdentityBackend()
        let expected = makeIdentity(seed: "9")
        backend.binding = binding(expected)
        backend.identitiesToCreate = [expected]

        XCTAssertThrowsError(
            try makeService(backend).requireHealthy(
                initializeIfMissing: false
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .unhealthy(.missing)
            )
        }
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.binding, binding(expected))
    }

    func testConcurrentInitializationConvergesOnOneBinding() throws {
        let backend = FakeSigningIdentityBackend()
        backend.createFactory = { index in
            self.makeIdentity(seed: String(index % 10))
        }
        let queue = DispatchQueue(
            label: "stable-signer-initialize",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let resultLock = NSLock()
        var results: [PlayCoverSigningIdentityResolution] = []
        var failures: [Error] = []

        for _ in 0..<24 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let value = try self.makeService(backend)
                        .initializeIfNeeded()
                    resultLock.lock()
                    results.append(value)
                    resultLock.unlock()
                } catch {
                    resultLock.lock()
                    failures.append(error)
                    resultLock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(results.count, 24)
        let certificates = Set(
            results.compactMap { $0.evidence?.certificateSHA256 }
        )
        XCTAssertEqual(certificates.count, 1)
        XCTAssertEqual(
            certificates.first,
            backend.binding?.certificateSHA256
        )
    }

    func testResolveClassifiesMissingBoundIdentityWithoutReplacement() throws {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(seed: "B")
        backend.binding = binding(identity)
        let service = makeService(backend)

        let result = service.resolve()

        XCTAssertEqual(result.health, .missing)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.binding, binding(identity))
    }

    func testResolveClassifiesSameKeyWithNewCertificateAsReplaced() {
        let backend = FakeSigningIdentityBackend()
        let original = makeIdentity(seed: "C")
        var replacement = makeIdentity(seed: "D")
        replacement = PlayCoverSigningIdentitySnapshot(
            publicKeySPKISHA256: original.publicKeySPKISHA256,
            certificateSHA256: replacement.certificateSHA256,
            codesignSelector: replacement.codesignSelector,
            notBefore: replacement.notBefore,
            notAfter: replacement.notAfter
        )
        backend.binding = binding(original)
        backend.identities = [replacement]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .replaced)
        XCTAssertEqual(result.evidence?.policy.health, .replaced)
        XCTAssertEqual(
            result.evidence?.certificateSHA256,
            replacement.certificateSHA256
        )
        XCTAssertEqual(backend.createCount, 0)
    }

    func testResolveDoesNotUseCommonNameOrAnotherFuzzyCandidate() {
        let backend = FakeSigningIdentityBackend()
        let original = makeIdentity(seed: "E")
        backend.binding = binding(original)
        backend.identities = [makeIdentity(seed: "F")]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .missing)
        XCTAssertNil(result.evidence)
    }

    func testResolveClassifiesExpiredIdentity() {
        let backend = FakeSigningIdentityBackend()
        let expired = makeIdentity(
            seed: "1",
            notBefore: now.addingTimeInterval(-200),
            notAfter: now
        )
        backend.binding = binding(expired)
        backend.identities = [expired]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .expired)
        XCTAssertEqual(result.evidence?.policy.health, .expired)
    }

    func testResolveClassifiesUntrustedBoundIdentityWithoutMutation() {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(
            seed: "D",
            trustedForCodeSigning: false
        )
        backend.binding = binding(identity)
        backend.identities = [identity]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .trustRequired)
        XCTAssertEqual(
            result.evidence?.policy.health,
            .trustRequired
        )
        XCTAssertEqual(backend.configureTrustCount, 0)
        XCTAssertEqual(backend.probeCount, 0)
    }

    func testResolveClassifiesBackendFailureAsUnavailable() {
        let backend = FakeSigningIdentityBackend()
        backend.failure = .read

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .unavailable)
        XCTAssertNil(result.evidence)
    }

    func testResolveClassifiesBoundPrivateKeyFailureAsInaccessible() {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(seed: "E")
        backend.binding = binding(identity)
        backend.identities = [identity]
        backend.failure = .inaccessible

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .inaccessible)
        XCTAssertNil(result.evidence)
        XCTAssertEqual(backend.createCount, 0)
    }

    func testResolveClassifiesNotYetValidIdentityAsUnavailable() {
        let backend = FakeSigningIdentityBackend()
        let future = makeIdentity(
            seed: "2",
            notBefore: now.addingTimeInterval(1),
            notAfter: now.addingTimeInterval(200)
        )
        backend.binding = binding(future)
        backend.identities = [future]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .unavailable)
        XCTAssertEqual(result.evidence?.policy.health, .unavailable)
    }

    func testResolveRejectsChangedSelectorEvenForSameCertificate() {
        let backend = FakeSigningIdentityBackend()
        let identity = makeIdentity(seed: "3")
        backend.binding = binding(identity)
        backend.identities = [
            PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256: identity.publicKeySPKISHA256,
                certificateSHA256: identity.certificateSHA256,
                codesignSelector: hex("4", 40),
                notBefore: identity.notBefore,
                notAfter: identity.notAfter
            ),
        ]

        let result = makeService(backend).resolve()

        XCTAssertEqual(result.health, .replaced)
    }

    func testInitializeWithExistingExpiredBindingDoesNotRotate() throws {
        let backend = FakeSigningIdentityBackend()
        let expired = makeIdentity(
            seed: "7",
            notBefore: now.addingTimeInterval(-200),
            notAfter: now
        )
        backend.binding = binding(expired)
        backend.identities = [expired]
        backend.identitiesToCreate = [makeIdentity(seed: "8")]

        let result = try makeService(backend).initializeIfNeeded()

        XCTAssertEqual(result.health, .expired)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.binding, binding(expired))
    }

    func testInvalidCreatedEvidenceIsRejectedBeforeBinding() {
        let backend = FakeSigningIdentityBackend()
        let invalid = PlayCoverSigningIdentitySnapshot(
            publicKeySPKISHA256: "not-a-digest",
            certificateSHA256: hex("9", 64),
            codesignSelector: hex("9", 40),
            notBefore: now,
            notAfter: now.addingTimeInterval(100)
        )
        backend.identitiesToCreate = [invalid]

        XCTAssertThrowsError(
            try makeService(backend).initializeIfNeeded()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .invalidCreatedIdentity
            )
        }
        XCTAssertNil(backend.binding)
    }

    func testCreationFailureIsNotMisclassifiedAsBindingFailure() {
        let backend = FakeSigningIdentityBackend()
        backend.failure = .create

        XCTAssertThrowsError(
            try makeService(backend).initializeIfNeeded()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .identityCreationUnavailable
            )
        }
        XCTAssertNil(backend.binding)
    }

    func testSignatureFailureMapsToIdentityCreationUnavailable() {
        let backend = FakeSigningIdentityBackend()
        backend.failure = .signature

        XCTAssertThrowsError(
            try makeService(backend).initializeIfNeeded()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .identityCreationUnavailable
            )
        }
        XCTAssertNil(backend.binding)
    }

    func testBindingClaimFailureRemainsBindingUnavailable() {
        let backend = FakeSigningIdentityBackend()
        backend.identitiesToCreate = [makeIdentity(seed: "D")]
        backend.failure = .claim

        XCTAssertThrowsError(
            try makeService(backend).initializeIfNeeded()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningIdentityServiceError,
                .bindingUnavailable
            )
        }
        XCTAssertNil(backend.binding)
    }

    func testBindingClaimCrashCutNeverPublishesPartialFinal()
        throws
    {
        let root = try makeTemporaryBindingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "binding",
            isDirectory: true
        )
        let expected = binding(makeIdentity(seed: "A"))
        let interrupted =
            SecurityPlayCoverSigningIdentityBackend(
                bindingDirectoryOverride: directory,
                afterTemporaryBindingSyncForTesting: {
                    throw BindingClaimTestError.interrupted
                }
            )

        XCTAssertThrowsError(
            try interrupted.claimInitialBinding(expected)
        ) {
            XCTAssertTrue($0 is BindingClaimTestError)
        }
        let reader = SecurityPlayCoverSigningIdentityBackend(
            bindingDirectoryOverride: directory
        )
        XCTAssertNil(try reader.readBinding())
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).contains(where: { $0.hasSuffix(".tmp") })
        )

        XCTAssertTrue(try reader.claimInitialBinding(expected))
        XCTAssertEqual(try reader.readBinding(), expected)
        try assertSafePublishedBinding(in: directory)
    }

    func testConcurrentBindingClaimHasOneWinnerAndValidatedLoser()
        throws
    {
        let root = try makeTemporaryBindingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "binding",
            isDirectory: true
        )
        let ready = DispatchGroup()
        ready.enter()
        ready.enter()
        let synchronizedAfterWrite: () throws -> Void = {
            ready.leave()
            guard ready.wait(timeout: .now() + 5) == .success else {
                throw BindingClaimTestError.interrupted
            }
        }
        let backends = [
            SecurityPlayCoverSigningIdentityBackend(
                bindingDirectoryOverride: directory,
                afterTemporaryBindingSyncForTesting:
                    synchronizedAfterWrite
            ),
            SecurityPlayCoverSigningIdentityBackend(
                bindingDirectoryOverride: directory,
                afterTemporaryBindingSyncForTesting:
                    synchronizedAfterWrite
            ),
        ]
        let bindings = [
            binding(makeIdentity(seed: "B")),
            binding(makeIdentity(seed: "C")),
        ]
        let queue = DispatchQueue(
            label: "binding-claim-race",
            attributes: .concurrent
        )
        let completion = DispatchGroup()
        let resultLock = NSLock()
        var winners: [Int] = []
        var losers: [Int] = []
        var failures: [Error] = []
        for index in backends.indices {
            completion.enter()
            queue.async {
                defer { completion.leave() }
                do {
                    let won = try backends[index]
                        .claimInitialBinding(bindings[index])
                    resultLock.withLock {
                        if won {
                            winners.append(index)
                        } else {
                            losers.append(index)
                        }
                    }
                } catch {
                    resultLock.withLock {
                        failures.append(error)
                    }
                }
            }
        }
        XCTAssertEqual(
            completion.wait(timeout: .now() + 10),
            .success
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(losers.count, 1)
        let winner = try XCTUnwrap(winners.first)
        let reader = SecurityPlayCoverSigningIdentityBackend(
            bindingDirectoryOverride: directory
        )
        XCTAssertEqual(try reader.readBinding(), bindings[winner])
        try assertSafePublishedBinding(in: directory)
        XCTAssertEqual(
            try Set(
                FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
            ),
            Set([PlayCoverSigningIdentityService.bindingFilename])
        )
    }

    func testBindingReadRejectsSymlinkedDirectoryAndMultiLinkFinal()
        throws
    {
        let root = try makeTemporaryBindingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "binding",
            isDirectory: true
        )
        let expected = binding(makeIdentity(seed: "F"))
        let backend = SecurityPlayCoverSigningIdentityBackend(
            bindingDirectoryOverride: directory
        )
        XCTAssertTrue(try backend.claimInitialBinding(expected))

        let final = directory.appendingPathComponent(
            PlayCoverSigningIdentityService.bindingFilename
        )
        let extraLink = root.appendingPathComponent("binding-copy")
        XCTAssertEqual(
            Darwin.link(final.path, extraLink.path),
            0
        )
        XCTAssertThrowsError(try backend.readBinding())
        XCTAssertEqual(Darwin.unlink(extraLink.path), 0)
        XCTAssertEqual(try backend.readBinding(), expected)

        let alias = root.appendingPathComponent(
            "binding-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: directory
        )
        let aliasedBackend =
            SecurityPlayCoverSigningIdentityBackend(
                bindingDirectoryOverride: alias
            )
        XCTAssertThrowsError(try aliasedBackend.readBinding())
    }

    func testBindingNamespaceAndSerializableEvidenceAreHomeIndependentAndSafe()
        throws
    {
        XCTAssertEqual(
            PlayCoverSigningIdentityService.bindingDirectoryName,
            "dev.ios-use"
        )
        XCTAssertEqual(
            PlayCoverSigningIdentityService.bindingFilename,
            "mac-stable-signing-binding-v1.json"
        )
        XCTAssertEqual(
            PlayCoverSigningIdentityService.policyRevision,
            "mac-stable-signer-v1"
        )
        let data = try JSONEncoder().encode(
            evidence(makeIdentity(seed: "A"))
        )
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "privateKey",
            "persistentRef",
            "keychainPath",
            "IOS_USE_HOME",
            "/Users/",
        ] {
            XCTAssertFalse(json.contains(forbidden), json)
        }
    }

    private func makeTemporaryBindingRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "ios-use-signing-binding-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func assertSafePublishedBinding(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = directory.appendingPathComponent(
            PlayCoverSigningIdentityService.bindingFilename
        )
        var status = stat()
        XCTAssertEqual(
            lstat(url.path, &status),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_mode & S_IFMT,
            S_IFREG,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_uid,
            geteuid(),
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_mode & 0o777,
            0o600,
            file: file,
            line: line
        )
        XCTAssertGreaterThan(status.st_size, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            status.st_size,
            1_048_576,
            file: file,
            line: line
        )
        XCTAssertEqual(status.st_nlink, 1, file: file, line: line)
    }

    private func makeService(
        _ backend: FakeSigningIdentityBackend
    ) -> PlayCoverSigningIdentityService {
        PlayCoverSigningIdentityService(
            backend: backend,
            now: { self.now },
            initializationLockURL: initializationLockURL
        )
    }

    private func makeIdentity(
        seed: String,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        trustedForCodeSigning: Bool = true
    ) -> PlayCoverSigningIdentitySnapshot {
        PlayCoverSigningIdentitySnapshot(
            publicKeySPKISHA256: hex(seed, 64),
            certificateSHA256: hex(seed, 64),
            codesignSelector: hex(seed, 40),
            notBefore:
                notBefore ?? now.addingTimeInterval(-100),
            notAfter:
                notAfter ?? now.addingTimeInterval(100),
            trustedForCodeSigning: trustedForCodeSigning
        )
    }

    private func binding(
        _ identity: PlayCoverSigningIdentitySnapshot
    ) -> PlayCoverSigningIdentityBinding {
        PlayCoverSigningIdentityBinding(
            snapshot: identity,
            policy: PlayCoverSigningIdentityPolicyEvidence(
                revision:
                    PlayCoverSigningIdentityService.policyRevision,
                source: .managedUserKeychain,
                health: .healthy
            )
        )
    }

    private func evidence(
        _ identity: PlayCoverSigningIdentitySnapshot,
        health: PlayCoverSigningIdentityHealth = .healthy
    ) -> PlayCoverSigningIdentityEvidence {
        PlayCoverSigningIdentityEvidence(
            publicKeySPKISHA256: identity.publicKeySPKISHA256,
            certificateSHA256: identity.certificateSHA256,
            codesignSelector: identity.codesignSelector,
            notBefore: identity.notBefore,
            notAfter: identity.notAfter,
            policy: PlayCoverSigningIdentityPolicyEvidence(
                revision:
                    PlayCoverSigningIdentityService.policyRevision,
                source: .managedUserKeychain,
                health: health
            )
        )
    }

    private func hex(_ seed: String, _ count: Int) -> String {
        String(repeating: seed, count: count)
    }
}

private final class FakeSigningIdentityBackend:
    PlayCoverSigningIdentityBackend
{
    enum Failure {
        case read
        case list
        case inaccessible
        case create
        case signature
        case claim
        case trust
        case trustUnavailable
        case probe
    }

    private let lock = NSLock()
    var binding: PlayCoverSigningIdentityBinding? {
        get {
            lock.withLock { storedBinding }
        }
        set {
            lock.withLock { storedBinding = newValue }
        }
    }
    var identities: [PlayCoverSigningIdentitySnapshot] {
        get {
            lock.withLock { storedIdentities }
        }
        set {
            lock.withLock { storedIdentities = newValue }
        }
    }
    var identitiesToCreate: [PlayCoverSigningIdentitySnapshot] = []
    var createFactory: ((Int) -> PlayCoverSigningIdentitySnapshot)?
    var failure: Failure?
    private(set) var createCount = 0
    private(set) var configureTrustCount = 0
    private(set) var probeCount = 0
    var trustFailuresRemaining = 0

    private var storedBinding: PlayCoverSigningIdentityBinding?
    private var storedIdentities: [PlayCoverSigningIdentitySnapshot] = []

    func readBinding() throws -> PlayCoverSigningIdentityBinding? {
        try lock.withLock {
            if failure == .read {
                throw FakeError.failed
            }
            return storedBinding
        }
    }

    func claimInitialBinding(
        _ binding: PlayCoverSigningIdentityBinding
    ) throws -> Bool {
        try lock.withLock {
            if failure == .claim {
                throw FakeError.failed
            }
            guard storedBinding == nil else {
                return false
            }
            storedBinding = binding
            return true
        }
    }

    func identitySnapshots(
        matching binding: PlayCoverSigningIdentityBinding
    )
        throws -> [PlayCoverSigningIdentitySnapshot]
    {
        try lock.withLock {
            if failure == .list {
                throw FakeError.failed
            }
            if failure == .inaccessible {
                throw PlayCoverSigningIdentityObservationError
                    .inaccessible
            }
            return storedIdentities.filter {
                $0.certificateSHA256 == binding.certificateSHA256
                    || $0.publicKeySPKISHA256
                        == binding.publicKeySPKISHA256
            }
        }
    }

    func createIdentity() throws -> PlayCoverSigningIdentitySnapshot {
        try lock.withLock {
            if failure == .create {
                throw FakeError.failed
            }
            if failure == .signature {
                throw PlayCoverSigningCertificateBuilderError
                    .signatureFailed
            }
            let index = createCount
            createCount += 1
            let identity: PlayCoverSigningIdentitySnapshot
            if let createFactory {
                identity = createFactory(index)
            } else {
                identity = identitiesToCreate.removeFirst()
            }
            storedIdentities.append(identity)
            return identity
        }
    }

    func configureCodeSigningTrust(
        certificateSHA256: String
    ) throws {
        try lock.withLock {
            configureTrustCount += 1
            if failure == .trustUnavailable {
                throw FakeError.failed
            }
            if failure == .trust || trustFailuresRemaining > 0 {
                if trustFailuresRemaining > 0 {
                    trustFailuresRemaining -= 1
                }
                throw PlayCoverSigningIdentityServiceError
                    .trustConfigurationFailed(errSecAuthFailed)
            }
            guard let index = storedIdentities.firstIndex(where: {
                $0.certificateSHA256 == certificateSHA256
            }) else {
                throw FakeError.failed
            }
            let identity = storedIdentities[index]
            storedIdentities[index] = PlayCoverSigningIdentitySnapshot(
                publicKeySPKISHA256:
                    identity.publicKeySPKISHA256,
                certificateSHA256:
                    identity.certificateSHA256,
                codesignSelector: identity.codesignSelector,
                notBefore: identity.notBefore,
                notAfter: identity.notAfter,
                trustedForCodeSigning: true
            )
        }
    }

    func probeCodeSigning(codesignSelector: String) throws {
        try lock.withLock {
            probeCount += 1
            if failure == .probe {
                throw PlayCoverSigningIdentityServiceError
                    .signingProbeFailed("fake failure")
            }
            guard storedIdentities.contains(where: {
                $0.codesignSelector == codesignSelector
                    && $0.trustedForCodeSigning
            }) else {
                throw FakeError.failed
            }
        }
    }
}

private enum FakeError: Error {
    case failed
}

private enum BindingClaimTestError: Error {
    case interrupted
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
