import CryptoKit
import Foundation
import Security
import XCTest
@testable import IOSUseCLI

final class PlayCoverSigningCertificateBuilderTests: XCTestCase {
    private static let rsa3072Key: Result<SecKey, Error> = Result {
        try makeEphemeralKey(
            type: kSecAttrKeyTypeRSA,
            sizeInBits: 3072
        )
    }

    func testBuildProducesParseableV3CertificateWithExpectedIdentity()
        throws
    {
        let privateKey = try Self.rsa3072Key.get()
        let notBefore = Date(timeIntervalSince1970: 1_767_225_600)
        let notAfter = Date(timeIntervalSince1970: 2_082_758_400)
        let serialNumber = Data([0x80, 0x01, 0x02, 0x03])

        let certificateDER =
            try PlayCoverSigningCertificateBuilder.build(
                privateKey: privateKey,
                serialNumber: serialNumber,
                notBefore: notBefore,
                notAfter: notAfter
            )
        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(
                nil,
                certificateDER as CFData
            )
        )

        XCTAssertEqual(
            try certificateDate(
                certificate,
                oid: kSecOIDX509V1ValidityNotBefore
            ),
            notBefore
        )
        XCTAssertEqual(
            try certificateDate(
                certificate,
                oid: kSecOIDX509V1ValidityNotAfter
            ),
            notAfter
        )

        let sourcePublicKey = try XCTUnwrap(
            SecKeyCopyPublicKey(privateKey)
        )
        let certificatePublicKey = try XCTUnwrap(
            SecCertificateCopyKey(certificate)
        )
        let sourcePublicKeyBytes = try externalRepresentation(
            sourcePublicKey
        )
        XCTAssertEqual(
            try externalRepresentation(certificatePublicKey),
            sourcePublicKeyBytes
        )
        let certificateKeyAttributes = try XCTUnwrap(
            SecKeyCopyAttributes(certificatePublicKey) as NSDictionary?
        )
        XCTAssertEqual(
            (
                certificateKeyAttributes.object(
                    forKey: kSecAttrKeySizeInBits
                ) as? NSNumber
            )?.intValue,
            3072
        )

        let certificateNode = try DERTestParser.single(certificateDER)
        XCTAssertEqual(certificateNode.tag, 0x30)
        let certificateFields = try certificateNode.children()
        XCTAssertEqual(certificateFields.count, 3)

        let tbsCertificate = certificateFields[0]
        let tbsFields = try tbsCertificate.children()
        XCTAssertEqual(tbsFields.count, 8)
        XCTAssertEqual(tbsFields[0].tag, 0xA0)
        XCTAssertEqual(
            try tbsFields[0].children().map(\.content),
            [Data([2])]
        )
        XCTAssertEqual(tbsFields[1].tag, 0x02)
        XCTAssertEqual(
            tbsFields[1].content,
            Data([0, 0x80, 0x01, 0x02, 0x03])
        )

        try assertRSAAlgorithm(
            tbsFields[2],
            oid: "1.2.840.113549.1.1.11"
        )
        XCTAssertEqual(tbsFields[3].encoded, tbsFields[5].encoded)
        XCTAssertEqual(
            try commonName(in: tbsFields[3]),
            "ios-use Mac Stable Code Signing"
        )

        let validity = try tbsFields[4].children()
        XCTAssertEqual(validity.count, 2)
        XCTAssertEqual(validity[0].tag, 0x17)
        XCTAssertEqual(
            String(decoding: validity[0].content, as: UTF8.self),
            "260101000000Z"
        )
        XCTAssertEqual(validity[1].tag, 0x17)
        XCTAssertEqual(
            String(decoding: validity[1].content, as: UTF8.self),
            "360101000000Z"
        )

        let subjectPublicKeyInfo = try tbsFields[6].children()
        XCTAssertEqual(subjectPublicKeyInfo.count, 2)
        try assertRSAAlgorithm(
            subjectPublicKeyInfo[0],
            oid: "1.2.840.113549.1.1.1"
        )
        XCTAssertEqual(subjectPublicKeyInfo[1].tag, 0x03)
        XCTAssertEqual(subjectPublicKeyInfo[1].content.first, 0)
        XCTAssertEqual(
            Data(subjectPublicKeyInfo[1].content.dropFirst()),
            sourcePublicKeyBytes
        )

        try assertRSAAlgorithm(
            certificateFields[1],
            oid: "1.2.840.113549.1.1.11"
        )
        XCTAssertEqual(
            certificateFields[1].encoded,
            tbsFields[2].encoded
        )
        XCTAssertEqual(certificateFields[2].tag, 0x03)
        XCTAssertEqual(certificateFields[2].content.first, 0)
        let signature = Data(certificateFields[2].content.dropFirst())
        XCTAssertEqual(signature.count, 384)
        var verificationError: Unmanaged<CFError>?
        XCTAssertTrue(
            SecKeyVerifySignature(
                sourcePublicKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                tbsCertificate.encoded as CFData,
                signature as CFData,
                &verificationError
            ),
            String(describing: verificationError?.takeRetainedValue())
        )
    }

    func testBuildEncodesRequiredCriticalCodeSigningExtensions()
        throws
    {
        let privateKey = try Self.rsa3072Key.get()
        let certificateDER =
            try PlayCoverSigningCertificateBuilder.build(
                privateKey: privateKey,
                serialNumber: Data([0x01]),
                notBefore: Date(
                    timeIntervalSince1970: 1_767_225_600
                ),
                notAfter: Date(
                    timeIntervalSince1970: 2_082_758_400
                )
            )

        let certificateFields =
            try DERTestParser.single(certificateDER).children()
        let tbsFields = try certificateFields[0].children()
        let extensionsField = try XCTUnwrap(
            tbsFields.first(where: { $0.tag == 0xA3 })
        )
        let extensions = try parseExtensions(extensionsField)
        XCTAssertEqual(
            Set(extensions.keys),
            Set([
                "2.5.29.14",
                "2.5.29.15",
                "2.5.29.19",
                "2.5.29.37",
            ])
        )

        let basicConstraints = try XCTUnwrap(
            extensions["2.5.29.19"]
        )
        XCTAssertTrue(basicConstraints.critical)
        let basicConstraintFields =
            try DERTestParser.single(
                basicConstraints.value
            ).children()
        XCTAssertEqual(basicConstraintFields.count, 2)
        XCTAssertEqual(basicConstraintFields[0].tag, 0x01)
        XCTAssertEqual(basicConstraintFields[0].content, Data([0xFF]))
        XCTAssertEqual(basicConstraintFields[1].tag, 0x02)
        XCTAssertEqual(basicConstraintFields[1].content, Data([0]))

        let keyUsage = try XCTUnwrap(extensions["2.5.29.15"])
        XCTAssertTrue(keyUsage.critical)
        let keyUsageBits = try DERTestParser.single(keyUsage.value)
        XCTAssertEqual(keyUsageBits.tag, 0x03)
        XCTAssertEqual(
            keyUsageBits.content,
            Data([2, 0x84]),
            "digitalSignature (bit 0) and keyCertSign (bit 5)"
        )

        let extendedKeyUsage = try XCTUnwrap(
            extensions["2.5.29.37"]
        )
        XCTAssertTrue(extendedKeyUsage.critical)
        let extendedKeyUsageFields =
            try DERTestParser.single(
                extendedKeyUsage.value
            ).children()
        XCTAssertEqual(extendedKeyUsageFields.count, 1)
        XCTAssertEqual(
            try decodeOID(extendedKeyUsageFields[0]),
            "1.3.6.1.5.5.7.3.3"
        )

        let subjectKeyIdentifier = try XCTUnwrap(
            extensions["2.5.29.14"]
        )
        XCTAssertFalse(subjectKeyIdentifier.critical)
        let identifier =
            try DERTestParser.single(subjectKeyIdentifier.value)
        XCTAssertEqual(identifier.tag, 0x04)
        let publicKey = try XCTUnwrap(
            SecKeyCopyPublicKey(privateKey)
        )
        XCTAssertEqual(
            identifier.content,
            Data(
                Insecure.SHA1.hash(
                    data: try externalRepresentation(publicKey)
                )
            )
        )
    }

    func testBuildRejectsInvalidValiditySerialAndNonRSA3072Key()
        throws
    {
        let rsaKey = try Self.rsa3072Key.get()
        let instant = Date(timeIntervalSince1970: 1_767_225_600)

        XCTAssertThrowsError(
            try PlayCoverSigningCertificateBuilder.build(
                privateKey: rsaKey,
                serialNumber: Data([1]),
                notBefore: instant,
                notAfter: instant.addingTimeInterval(0.5)
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningCertificateBuilderError,
                .invalidValidity
            )
        }
        for serialNumber in [
            Data(),
            Data([0, 0, 0]),
            Data([0x80]) + Data(repeating: 1, count: 19),
        ] {
            XCTAssertThrowsError(
                try PlayCoverSigningCertificateBuilder.build(
                    privateKey: rsaKey,
                    serialNumber: serialNumber,
                    notBefore: instant,
                    notAfter: instant.addingTimeInterval(60)
                )
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverSigningCertificateBuilderError,
                    .invalidSerialNumber
                )
            }
        }

        let ecKey = try makeEphemeralKey(
            type: kSecAttrKeyTypeECSECPrimeRandom,
            sizeInBits: 256
        )
        XCTAssertThrowsError(
            try PlayCoverSigningCertificateBuilder.build(
                privateKey: ecKey,
                serialNumber: Data([1]),
                notBefore: instant,
                notAfter: instant.addingTimeInterval(60)
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverSigningCertificateBuilderError,
                .unsupportedPrivateKey
            )
        }
    }

    private func certificateDate(
        _ certificate: SecCertificate,
        oid: CFString
    ) throws -> Date {
        var error: Unmanaged<CFError>?
        let values = try XCTUnwrap(
            SecCertificateCopyValues(
                certificate,
                [oid] as CFArray,
                &error
            ) as NSDictionary?,
            String(describing: error?.takeRetainedValue())
        )
        let property = try XCTUnwrap(
            values.object(forKey: oid) as? NSDictionary
        )
        let value = property.object(forKey: kSecPropertyKeyValue)
        if let date = value as? Date {
            return date
        }
        if let secondsSinceReferenceDate = value as? NSNumber {
            return Date(
                timeIntervalSinceReferenceDate:
                    secondsSinceReferenceDate.doubleValue
            )
        }
        throw DERTestError.malformed
    }

    private func externalRepresentation(
        _ key: SecKey
    ) throws -> Data {
        var error: Unmanaged<CFError>?
        return try XCTUnwrap(
            SecKeyCopyExternalRepresentation(
                key,
                &error
            ) as Data?,
            String(describing: error?.takeRetainedValue())
        )
    }

    private func commonName(in name: DERTestNode) throws -> String {
        let relativeNames = try name.children()
        XCTAssertEqual(relativeNames.count, 1)
        let attributes = try relativeNames[0].children()
        XCTAssertEqual(attributes.count, 1)
        let fields = try attributes[0].children()
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(try decodeOID(fields[0]), "2.5.4.3")
        XCTAssertEqual(fields[1].tag, 0x0C)
        return String(decoding: fields[1].content, as: UTF8.self)
    }

    private func assertRSAAlgorithm(
        _ node: DERTestNode,
        oid: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(node.tag, 0x30, file: file, line: line)
        let fields = try node.children()
        XCTAssertEqual(fields.count, 2, file: file, line: line)
        XCTAssertEqual(
            try decodeOID(fields[0]),
            oid,
            file: file,
            line: line
        )
        XCTAssertEqual(fields[1].tag, 0x05, file: file, line: line)
        XCTAssertTrue(
            fields[1].content.isEmpty,
            file: file,
            line: line
        )
    }
}

private struct ParsedCertificateExtension {
    let critical: Bool
    let value: Data
}

private func parseExtensions(
    _ explicitExtensions: DERTestNode
) throws -> [String: ParsedCertificateExtension] {
    let explicitFields = try explicitExtensions.children()
    guard explicitFields.count == 1,
          explicitFields[0].tag == 0x30 else {
        throw DERTestError.malformed
    }
    var result: [String: ParsedCertificateExtension] = [:]
    for extensionNode in try explicitFields[0].children() {
        let fields = try extensionNode.children()
        guard fields.count == 2 || fields.count == 3 else {
            throw DERTestError.malformed
        }
        let oid = try decodeOID(fields[0])
        let critical: Bool
        let valueField: DERTestNode
        if fields.count == 3 {
            guard fields[1].tag == 0x01,
                  fields[1].content == Data([0xFF]) else {
                throw DERTestError.malformed
            }
            critical = true
            valueField = fields[2]
        } else {
            critical = false
            valueField = fields[1]
        }
        guard valueField.tag == 0x04, result[oid] == nil else {
            throw DERTestError.malformed
        }
        result[oid] = ParsedCertificateExtension(
            critical: critical,
            value: valueField.content
        )
    }
    return result
}

private func decodeOID(_ node: DERTestNode) throws -> String {
    guard node.tag == 0x06, !node.content.isEmpty else {
        throw DERTestError.malformed
    }
    let encodedComponents = try decodeBase128Components(node.content)
    guard let firstCombined = encodedComponents.first else {
        throw DERTestError.malformed
    }
    let first: UInt64
    let second: UInt64
    if firstCombined < 40 {
        first = 0
        second = firstCombined
    } else if firstCombined < 80 {
        first = 1
        second = firstCombined - 40
    } else {
        first = 2
        second = firstCombined - 80
    }
    return ([first, second] + encodedComponents.dropFirst()).map(
        String.init
    ).joined(separator: ".")
}

private func decodeBase128Components(
    _ data: Data
) throws -> [UInt64] {
    var result: [UInt64] = []
    var value: UInt64 = 0
    var hasByte = false
    for byte in data {
        guard value <= (UInt64.max >> 7) else {
            throw DERTestError.malformed
        }
        value = (value << 7) | UInt64(byte & 0x7F)
        hasByte = true
        if byte & 0x80 == 0 {
            result.append(value)
            value = 0
            hasByte = false
        }
    }
    guard !hasByte else {
        throw DERTestError.malformed
    }
    return result
}

private struct DERTestNode {
    let tag: UInt8
    let content: Data
    let encoded: Data

    func children() throws -> [DERTestNode] {
        try DERTestParser.all(content)
    }
}

private enum DERTestError: Error {
    case malformed
}

private enum DERTestParser {
    static func single(_ data: Data) throws -> DERTestNode {
        let nodes = try all(data)
        guard nodes.count == 1 else {
            throw DERTestError.malformed
        }
        return nodes[0]
    }

    static func all(_ data: Data) throws -> [DERTestNode] {
        let bytes = Array(data)
        var offset = 0
        var result: [DERTestNode] = []
        while offset < bytes.count {
            result.append(try parse(bytes, offset: &offset))
        }
        return result
    }

    private static func parse(
        _ bytes: [UInt8],
        offset: inout Int
    ) throws -> DERTestNode {
        let start = offset
        guard offset + 2 <= bytes.count else {
            throw DERTestError.malformed
        }
        let tag = bytes[offset]
        offset += 1
        let firstLengthByte = bytes[offset]
        offset += 1

        let contentLength: Int
        if firstLengthByte & 0x80 == 0 {
            contentLength = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0,
                  lengthByteCount <= MemoryLayout<Int>.size,
                  offset + lengthByteCount <= bytes.count,
                  bytes[offset] != 0 else {
                throw DERTestError.malformed
            }
            var value = 0
            for byte in bytes[offset ..< offset + lengthByteCount] {
                guard value <= (Int.max >> 8) else {
                    throw DERTestError.malformed
                }
                value = (value << 8) | Int(byte)
            }
            guard value >= 128 else {
                throw DERTestError.malformed
            }
            offset += lengthByteCount
            contentLength = value
        }

        guard contentLength <= bytes.count - offset else {
            throw DERTestError.malformed
        }
        let contentStart = offset
        let end = offset + contentLength
        offset = end
        return DERTestNode(
            tag: tag,
            content: Data(bytes[contentStart ..< end]),
            encoded: Data(bytes[start ..< end])
        )
    }
}

private func makeEphemeralKey(
    type: CFString,
    sizeInBits: Int
) throws -> SecKey {
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(
        [
            kSecAttrKeyType as String: type,
            kSecAttrKeySizeInBits as String: sizeInBits,
            kSecAttrIsPermanent as String: false,
        ] as CFDictionary,
        &error
    ) else {
        throw error?.takeRetainedValue()
            ?? DERTestError.malformed
    }
    return key
}
