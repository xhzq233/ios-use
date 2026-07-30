import CryptoKit
import Foundation
import Security

enum PlayCoverSigningCertificateBuilderError: Error, Equatable {
    case invalidValidity
    case invalidSerialNumber
    case unsupportedPrivateKey
    case publicKeyUnavailable
    case publicKeyExportFailed
    case signatureFailed
}

/// Builds the stable self-signed certificate used by the Mac backend signer.
///
/// DER is produced in-process so certificate creation does not depend on
/// Keychain state, an external tool, or a mutable OpenSSL configuration.
enum PlayCoverSigningCertificateBuilder {
    static let subjectCommonName =
        "ios-use Mac Stable Code Signing"

    static func build(
        privateKey: SecKey,
        serialNumber: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        let normalizedNotBefore = wholeSecond(notBefore)
        let normalizedNotAfter = wholeSecond(notAfter)
        guard normalizedNotBefore < normalizedNotAfter else {
            throw PlayCoverSigningCertificateBuilderError.invalidValidity
        }

        let serial = try derSerialNumber(serialNumber)
        let publicKeyBytes = try rsa3072PublicKeyBytes(
            privateKey: privateKey
        )
        let signatureAlgorithm = derSequence(
            derOID([1, 2, 840, 113549, 1, 1, 11]) + derNull()
        )
        let name = distinguishedName(commonName: subjectCommonName)
        let subjectPublicKeyInfo = derSequence(
            derSequence(
                derOID([1, 2, 840, 113549, 1, 1, 1]) + derNull()
            )
                + derBitString(publicKeyBytes)
        )
        let validity = derSequence(
            try derTime(normalizedNotBefore)
                + derTime(normalizedNotAfter)
        )
        let extensions = certificateExtensions(
            subjectPublicKey: publicKeyBytes
        )

        let tbsCertificate = derSequence(
            derExplicit(tagNumber: 0, content: derInteger(Data([2])))
                + serial
                + signatureAlgorithm
                + name
                + validity
                + name
                + subjectPublicKeyInfo
                + derExplicit(tagNumber: 3, content: extensions)
        )

        guard SecKeyIsAlgorithmSupported(
            privateKey,
            .sign,
            .rsaSignatureMessagePKCS1v15SHA256
        ) else {
            throw PlayCoverSigningCertificateBuilderError
                .unsupportedPrivateKey
        }
        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) as Data? else {
            throw PlayCoverSigningCertificateBuilderError.signatureFailed
        }

        return derSequence(
            tbsCertificate
                + signatureAlgorithm
                + derBitString(signature)
        )
    }

    private static func rsa3072PublicKeyBytes(
        privateKey: SecKey
    ) throws -> Data {
        guard let attributes =
                SecKeyCopyAttributes(privateKey) as NSDictionary?,
              let keyType = attributes.object(
                  forKey: kSecAttrKeyType
              ) as? String,
              keyType == kSecAttrKeyTypeRSA as String,
              let keySize = attributes.object(
                  forKey: kSecAttrKeySizeInBits
              ) as? NSNumber,
              keySize.intValue == 3072
        else {
            throw PlayCoverSigningCertificateBuilderError
                .unsupportedPrivateKey
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw PlayCoverSigningCertificateBuilderError
                .publicKeyUnavailable
        }
        var exportError: Unmanaged<CFError>?
        guard let publicKeyBytes = SecKeyCopyExternalRepresentation(
            publicKey,
            &exportError
        ) as Data? else {
            throw PlayCoverSigningCertificateBuilderError
                .publicKeyExportFailed
        }
        return publicKeyBytes
    }

    private static func certificateExtensions(
        subjectPublicKey: Data
    ) -> Data {
        let basicConstraints = extensionValue(
            oid: [2, 5, 29, 19],
            critical: true,
            value: derSequence(
                derBoolean(true) + derInteger(Data([0]))
            )
        )
        let keyUsage = extensionValue(
            oid: [2, 5, 29, 15],
            critical: true,
            value: derBitString(
                Data([0x84]),
                unusedBitCount: 2
            )
        )
        let extendedKeyUsage = extensionValue(
            oid: [2, 5, 29, 37],
            critical: true,
            value: derSequence(
                derOID([1, 3, 6, 1, 5, 5, 7, 3, 3])
            )
        )
        let subjectKeyIdentifier = extensionValue(
            oid: [2, 5, 29, 14],
            critical: false,
            value: derOctetString(
                Data(Insecure.SHA1.hash(data: subjectPublicKey))
            )
        )
        return derSequence(
            basicConstraints
                + keyUsage
                + extendedKeyUsage
                + subjectKeyIdentifier
        )
    }

    private static func extensionValue(
        oid: [UInt64],
        critical: Bool,
        value: Data
    ) -> Data {
        derSequence(
            derOID(oid)
                + (critical ? derBoolean(true) : Data())
                + derOctetString(value)
        )
    }

    private static func distinguishedName(
        commonName: String
    ) -> Data {
        let attribute = derSequence(
            derOID([2, 5, 4, 3])
                + derValue(
                    tag: 0x0C,
                    content: Data(commonName.utf8)
                )
        )
        return derSequence(derValue(tag: 0x31, content: attribute))
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate:
                floor(date.timeIntervalSinceReferenceDate)
        )
    }

    private static func derTime(_ date: Date) throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard let year = components.year,
              (1 ... 9999).contains(year),
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else {
            throw PlayCoverSigningCertificateBuilderError.invalidValidity
        }

        let value: String
        let tag: UInt8
        if (1950 ... 2049).contains(year) {
            value = String(
                format: "%02d%02d%02d%02d%02d%02dZ",
                year % 100,
                month,
                day,
                hour,
                minute,
                second
            )
            tag = 0x17
        } else {
            value = String(
                format: "%04d%02d%02d%02d%02d%02dZ",
                year,
                month,
                day,
                hour,
                minute,
                second
            )
            tag = 0x18
        }
        return derValue(tag: tag, content: Data(value.utf8))
    }

    private static func derSerialNumber(_ serial: Data) throws -> Data {
        var magnitude = Array(serial)
        while magnitude.first == 0 {
            magnitude.removeFirst()
        }
        guard !magnitude.isEmpty else {
            throw PlayCoverSigningCertificateBuilderError
                .invalidSerialNumber
        }
        if magnitude[0] & 0x80 != 0 {
            magnitude.insert(0, at: 0)
        }
        guard magnitude.count <= 20 else {
            throw PlayCoverSigningCertificateBuilderError
                .invalidSerialNumber
        }
        return derInteger(Data(magnitude))
    }

    private static func derSequence(_ content: Data) -> Data {
        derValue(tag: 0x30, content: content)
    }

    private static func derExplicit(
        tagNumber: UInt8,
        content: Data
    ) -> Data {
        precondition(tagNumber < 31)
        return derValue(tag: 0xA0 | tagNumber, content: content)
    }

    private static func derInteger(_ unsignedContent: Data) -> Data {
        derValue(tag: 0x02, content: unsignedContent)
    }

    private static func derBoolean(_ value: Bool) -> Data {
        derValue(
            tag: 0x01,
            content: Data([value ? 0xFF : 0x00])
        )
    }

    private static func derNull() -> Data {
        derValue(tag: 0x05, content: Data())
    }

    private static func derOctetString(_ content: Data) -> Data {
        derValue(tag: 0x04, content: content)
    }

    private static func derBitString(
        _ content: Data,
        unusedBitCount: UInt8 = 0
    ) -> Data {
        precondition(unusedBitCount < 8)
        return derValue(
            tag: 0x03,
            content: Data([unusedBitCount]) + content
        )
    }

    private static func derValue(
        tag: UInt8,
        content: Data
    ) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private static func derLength(_ count: Int) -> Data {
        precondition(count >= 0)
        if count < 128 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func derOID(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        precondition(components[0] <= 2)
        precondition(components[0] == 2 || components[1] < 40)

        var content = base128(
            components[0] * 40 + components[1]
        )
        for component in components.dropFirst(2) {
            content.append(base128(component))
        }
        return derValue(tag: 0x06, content: content)
    }

    private static func base128(_ component: UInt64) -> Data {
        var value = component
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return Data(bytes)
    }
}
