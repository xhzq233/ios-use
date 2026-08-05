import CryptoKit
import Darwin
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
    case filesystem(String, Int32)
    case missing(String)

    var description: String {
        switch self {
        case .operation(let operation, let status):
            return "\(operation) failed with Security status \(status)"
        case .filesystem(let operation, let errorNumber):
            return "\(operation) failed with errno \(errorNumber)"
        case .missing(let field):
            return "code signature is missing \(field)"
        }
    }
}

enum PlayCoverCodeSignatureInspector {
    static func inspectRoot(
        appURL: URL,
        mainExecutableRelativePath: String,
        scratchRootURL: URL
    ) throws -> PlayCoverRootCodeSignatureEvidence {
        try withStaticCode(
            appURL: appURL,
            mainExecutableRelativePath: mainExecutableRelativePath,
            scratchRootURL: scratchRootURL
        ) { code, validateWithSecurity in
            try inspect(
                code,
                validateWithSecurity: validateWithSecurity
            )
        }
    }

    private static func inspect(
        _ code: SecStaticCode,
        validateWithSecurity: Bool
    ) throws -> PlayCoverRootCodeSignatureEvidence {
        if validateWithSecurity {
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

    private static func withStaticCode<T>(
        appURL: URL,
        mainExecutableRelativePath: String,
        scratchRootURL: URL,
        _ body: (SecStaticCode, Bool) throws -> T
    ) throws -> T {
        var code: SecStaticCode?
        let createStatus = autoreleasepool {
            SecStaticCodeCreateWithPath(
                appURL as CFURL,
                SecCSFlags(),
                &code
            )
        }
        if createStatus == errSecSuccess, let code {
            return try body(code, true)
        }
        // Converted iOS bundles can be a valid outer code object while
        // Security.framework still classifies their on-disk layout as
        // `errSecCSAmbiguousBundleFormat`. The immediately preceding pinned
        // root `codesign --verify --strict` remains the authoritative resource
        // seal; inspect the exact root main Mach-O CodeDirectory for signer,
        // requirement, identifier and CDHash evidence.
        guard createStatus == errSecCSAmbiguousBundleFormat,
              isSafeRootExecutableName(
                mainExecutableRelativePath
              ) else {
            throw PlayCoverCodeSignatureInspectorError.operation(
                "SecStaticCodeCreateWithPath",
                createStatus
            )
        }
        let executableURL = appURL.appendingPathComponent(
            mainExecutableRelativePath,
            isDirectory: false
        )
        return try withTemporaryExecutableHardLink(
            executableURL: executableURL,
            scratchRootURL: scratchRootURL
        ) { linkedExecutableURL in
            try autoreleasepool {
                var executableCode: SecStaticCode?
                let executableStatus = SecStaticCodeCreateWithPath(
                    linkedExecutableURL as CFURL,
                    SecCSFlags(),
                    &executableCode
                )
                guard executableStatus == errSecSuccess,
                      executableCode != nil else {
                    throw PlayCoverCodeSignatureInspectorError.operation(
                        "SecStaticCodeCreateWithPath(main executable)",
                        executableStatus
                    )
                }
                // The isolated same-inode view is used only to extract the
                // root main CodeDirectory's signer, requirement, identifier
                // and CDHash. Its Info.plist special slot remains bound to the
                // verified outer bundle, so standalone validity is not
                // meaningful.
                do {
                    let result = try body(executableCode!, false)
                    executableCode = nil
                    return result
                } catch {
                    executableCode = nil
                    throw error
                }
            }
        }
    }

    private static func withTemporaryExecutableHardLink<T>(
        executableURL: URL,
        scratchRootURL: URL,
        _ body: (URL) throws -> T
    ) throws -> T {
        let scratchDescriptor = Darwin.open(
            scratchRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scratchDescriptor >= 0 else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "open signature-inspection scratch root",
                errno
            )
        }
        defer { Darwin.close(scratchDescriptor) }
        var scratchStatus = stat()
        guard fstat(scratchDescriptor, &scratchStatus) == 0,
              scratchStatus.st_mode & S_IFMT == S_IFDIR,
              scratchStatus.st_uid == geteuid(),
              scratchStatus.st_mode & 0o077 == 0 else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "validate signature-inspection scratch root",
                errno
            )
        }

        let linkedName =
            ".signature-inspection-\(UUID().uuidString.lowercased())"
        guard Darwin.linkat(
                AT_FDCWD,
                executableURL.path,
                scratchDescriptor,
                linkedName,
                0
              ) == 0 else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "hard-link root main executable",
                errno
            )
        }
        var linkedExists = true
        defer {
            if linkedExists {
                _ = Darwin.unlinkat(
                    scratchDescriptor,
                    linkedName,
                    0
                )
            }
        }
        let linkedDescriptor = Darwin.openat(
            scratchDescriptor,
            linkedName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard linkedDescriptor >= 0 else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "open hard-linked root main executable",
                errno
            )
        }
        var linkedDescriptorIsOpen = true
        defer {
            if linkedDescriptorIsOpen {
                Darwin.close(linkedDescriptor)
            }
        }

        var sourceBefore = stat()
        var linkedBefore = stat()
        guard lstat(executableURL.path, &sourceBefore) == 0,
              fstat(linkedDescriptor, &linkedBefore) == 0,
              linkedBefore.st_mode & S_IFMT == S_IFREG,
              linkedBefore.st_uid == geteuid(),
              sameFileIdentity(sourceBefore, linkedBefore) else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "validate hard-linked root main executable",
                errno
            )
        }
        let stableDirectoryURL =
            try PlayCoverManagedAppService.ownedDirectoryDescriptorPath(
                scratchDescriptor,
                label: "signature-inspection scratch root"
            )
        let inspectionResult: Result<T, Error>
        do {
            let value = try body(
                stableDirectoryURL.appendingPathComponent(
                    linkedName,
                    isDirectory: false
                )
            )
            var sourceAfter = stat()
            var linkedAfter = stat()
            var linkedPathAfter = stat()
            guard lstat(executableURL.path, &sourceAfter) == 0,
                  fstat(linkedDescriptor, &linkedAfter) == 0,
                  fstatat(
                    scratchDescriptor,
                    linkedName,
                    &linkedPathAfter,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameFileIdentity(sourceBefore, sourceAfter),
                  sameFileIdentity(linkedBefore, linkedAfter),
                  sameFileIdentity(linkedBefore, linkedPathAfter) else {
                throw PlayCoverCodeSignatureInspectorError.filesystem(
                    "revalidate hard-linked root main executable",
                    errno
                )
            }
            inspectionResult = .success(value)
        } catch {
            inspectionResult = .failure(error)
        }
        guard Darwin.unlinkat(
                scratchDescriptor,
                linkedName,
                0
              ) == 0 else {
            throw PlayCoverCodeSignatureInspectorError.filesystem(
                "remove hard-linked root main executable",
                errno
            )
        }
        linkedExists = false
        Darwin.close(linkedDescriptor)
        linkedDescriptorIsOpen = false
        return try inspectionResult.get()
    }

    private static func sameFileIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_size == rhs.st_size
    }

    private static func isSafeRootExecutableName(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
    }

    private static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
