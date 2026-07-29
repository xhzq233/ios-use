import CryptoKit
import Foundation
import Security

public struct PlayCoverRootCodeSignatureEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let certificateSHA256: String
    public let designatedRequirement: Data
    public let designatedRequirementSHA256: String
    public let cdHash: String
    public let signingIdentifier: String
    public let teamIdentifier: String?

    public init(
        certificateSHA256: String,
        designatedRequirement: Data,
        designatedRequirementSHA256: String,
        cdHash: String,
        signingIdentifier: String,
        teamIdentifier: String?
    ) {
        self.certificateSHA256 = certificateSHA256
        self.designatedRequirement = designatedRequirement
        self.designatedRequirementSHA256 =
            designatedRequirementSHA256
        self.cdHash = cdHash
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

enum PlayCoverCodeSignatureInspectorError:
    Error,
    CustomStringConvertible
{
    case operation(String, OSStatus)
    case missing(String)

    var description: String {
        switch self {
        case .operation(let operation, let status):
            return "\(operation) failed with Security status \(status)"
        case .missing(let field):
            return "code signature is missing \(field)"
        }
    }
}

enum PlayCoverCodeSignatureInspector {
    static func inspectRoot(
        appURL: URL
    ) throws -> PlayCoverRootCodeSignatureEvidence {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &code
        )
        guard createStatus == errSecSuccess, let code else {
            throw PlayCoverCodeSignatureInspectorError.operation(
                "SecStaticCodeCreateWithPath",
                createStatus
            )
        }

        var validityErrors: Unmanaged<CFError>?
        let validityStatus = SecStaticCodeCheckValidityWithErrors(
            code,
            SecCSFlags(
                rawValue:
                    UInt32(kSecCSStrictValidate)
                    | UInt32(kSecCSCheckAllArchitectures)
            ),
            nil,
            &validityErrors
        )
        guard validityStatus == errSecSuccess else {
            throw PlayCoverCodeSignatureInspectorError.operation(
                "SecStaticCodeCheckValidityWithErrors",
                validityStatus
            )
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(
                rawValue:
                    UInt32(kSecCSSigningInformation)
                    | UInt32(kSecCSRequirementInformation)
            ),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any]
        else {
            throw PlayCoverCodeSignatureInspectorError.operation(
                "SecCodeCopySigningInformation",
                informationStatus
            )
        }
        guard let certificates =
                information[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first else {
            throw PlayCoverCodeSignatureInspectorError.missing(
                "a non-ad-hoc leaf certificate"
            )
        }
        guard let rawRequirementObject =
                information[kSecCodeInfoDesignatedRequirement] else {
            throw PlayCoverCodeSignatureInspectorError.missing(
                "the designated requirement"
            )
        }
        let requirementObject = rawRequirementObject as CFTypeRef
        guard CFGetTypeID(requirementObject)
                == SecRequirementGetTypeID() else {
            throw PlayCoverCodeSignatureInspectorError.missing(
                "a valid designated requirement"
            )
        }
        let requirement = unsafeBitCast(
            requirementObject,
            to: SecRequirement.self
        )
        var rawRequirement: CFData?
        let requirementStatus = SecRequirementCopyData(
            requirement,
            SecCSFlags(),
            &rawRequirement
        )
        guard requirementStatus == errSecSuccess,
              let designatedRequirement = rawRequirement as Data?
        else {
            throw PlayCoverCodeSignatureInspectorError.operation(
                "SecRequirementCopyData",
                requirementStatus
            )
        }
        guard let cdHash = information[kSecCodeInfoUnique] as? Data,
              !cdHash.isEmpty else {
            throw PlayCoverCodeSignatureInspectorError.missing("CDHash")
        }
        guard let signingIdentifier =
                information[kSecCodeInfoIdentifier] as? String,
              !signingIdentifier.isEmpty else {
            throw PlayCoverCodeSignatureInspectorError.missing(
                "the signing identifier"
            )
        }
        let certificate = SecCertificateCopyData(leaf) as Data
        return PlayCoverRootCodeSignatureEvidence(
            certificateSHA256: sha256(certificate),
            designatedRequirement: designatedRequirement,
            designatedRequirementSHA256:
                sha256(designatedRequirement),
            cdHash: hex(cdHash),
            signingIdentifier: signingIdentifier,
            teamIdentifier:
                information[kSecCodeInfoTeamIdentifier] as? String
        )
    }

    private static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
