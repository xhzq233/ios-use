import CryptoKit
import Foundation
@testable import IOSUseCLI

func makePlayCoverTestSigningIdentity(
    seed: Character = "A",
    codesignSelector: String? = nil
) -> PlayCoverSigningIdentityEvidence {
    let value = String(seed)
    return PlayCoverSigningIdentityEvidence(
        publicKeySPKISHA256: String(repeating: value, count: 64),
        certificateSHA256: String(repeating: value, count: 64),
        codesignSelector:
            codesignSelector
                ?? String(repeating: value, count: 40),
        notBefore: Date(timeIntervalSince1970: 1_577_836_800),
        notAfter: Date(timeIntervalSince1970: 2_524_608_000),
        policy: PlayCoverSigningIdentityPolicyEvidence(
            revision: PlayCoverSigningIdentityService.policyRevision,
            source: .managedUserKeychain,
            health: .healthy
        )
    )
}

func makePlayCoverTestRootCodeSignature(
    bundleIdentifier: String,
    identity: PlayCoverSigningIdentityEvidence =
        makePlayCoverTestSigningIdentity(),
    cdHash: String? = nil,
    cdHashSeed: Character = "B"
) -> PlayCoverRootCodeSignatureEvidence {
    let requirement = Data(
        "ios-use-test-dr:\(identity.certificateSHA256):"
            .appending(bundleIdentifier)
            .utf8
    )
    return PlayCoverRootCodeSignatureEvidence(
        certificateSHA256: identity.certificateSHA256,
        designatedRequirement: requirement,
        designatedRequirementSHA256:
            SHA256.hash(data: requirement).map {
                String(format: "%02X", $0)
            }.joined(),
        cdHash:
            cdHash
                ?? String(repeating: String(cdHashSeed), count: 40),
        signingIdentifier: bundleIdentifier,
        teamIdentifier: nil
    )
}
