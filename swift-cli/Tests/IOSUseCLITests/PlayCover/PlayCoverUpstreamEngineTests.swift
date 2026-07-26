import Foundation
import PlayCoverUpstream
import XCTest

final class PlayCoverUpstreamEngineTests: XCTestCase {
    func testContentHashPreservesFramedContractAndPathSemantics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverUpstreamHash-\(UUID().uuidString)",
                isDirectory: true
            )
        let first = root.appendingPathComponent(
            "First.app",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            "Second.app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try makeHashFixture(at: first)
        try makeHashFixture(at: second)

        let firstHash = try PlayCoverUpstreamEngine.contentHash(appURL: first)
        let secondHash = try PlayCoverUpstreamEngine.contentHash(appURL: second)

        XCTAssertEqual(
            firstHash,
            "f4693b28619063e898421b59e2b571ec391c6a838e3dea858cc349ea9540ded2",
            "the length-framed path/kind/mode/size/content contract is pinned"
        )
        XCTAssertEqual(
            firstHash,
            secondHash,
            "the root source path must not participate in the content hash"
        )

        let secondA = second.appendingPathComponent("A.txt")
        let secondRenamed = second.appendingPathComponent("Q.txt")
        try FileManager.default.moveItem(at: secondA, to: secondRenamed)
        XCTAssertNotEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: second),
            firstHash,
            "relative paths must participate in the content hash"
        )
        try FileManager.default.moveItem(at: secondRenamed, to: secondA)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: secondA.path
        )
        XCTAssertNotEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: second),
            firstHash,
            "POSIX permissions must participate in the content hash"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: secondA.path
        )

        let firstLink = first.appendingPathComponent("Alias")
        let secondLink = second.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(
            atPath: firstLink.path,
            withDestinationPath: "A.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: secondLink.path,
            withDestinationPath: "A.txt"
        )
        XCTAssertEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: first),
            try PlayCoverUpstreamEngine.contentHash(appURL: second),
            "identical relative symlinks must remain root-path independent"
        )
        try FileManager.default.removeItem(at: secondLink)
        try FileManager.default.createSymbolicLink(
            atPath: secondLink.path,
            withDestinationPath: "z.bin"
        )
        XCTAssertNotEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: first),
            try PlayCoverUpstreamEngine.contentHash(appURL: second),
            "the lexical symlink destination must participate in the hash"
        )
    }

    func testAppInspectionMatchesDirectThinAndFatMachOEvidence() throws {
        let fixture = try makeInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let thinURL = fixture.app.appendingPathComponent("Fixture")
        let fatURL = fixture.app.appendingPathComponent(
            "Frameworks/FatFixture"
        )
        let thinBytesBefore = try Data(contentsOf: thinURL)
        let fatBytesBefore = try Data(contentsOf: fatURL)
        let directThin = try PlayCoverUpstreamEngine.inspectMachO(
            at: thinURL,
            relativePath: "Fixture"
        )
        let directFat = try PlayCoverUpstreamEngine.inspectMachO(
            at: fatURL,
            relativePath: "Frameworks/FatFixture"
        )

        let appInspection = try PlayCoverUpstreamEngine.inspect(
            appURL: fixture.app
        )

        XCTAssertEqual(
            appInspection.machOs.first {
                $0.relativePath == "Fixture"
            },
            directThin
        )
        XCTAssertEqual(
            appInspection.machOs.first {
                $0.relativePath == "Frameworks/FatFixture"
            },
            directFat
        )
        XCTAssertEqual(directThin.container, .thin)
        XCTAssertEqual(directThin.allSlices.count, 1)
        XCTAssertEqual(directFat.container, .fat)
        XCTAssertEqual(directFat.allSlices.count, 2)
        XCTAssertEqual(
            appInspection.inventory.first {
                $0.relativePath == "Fixture"
            }?.sha256,
            directThin.fileSHA256
        )
        XCTAssertEqual(
            appInspection.inventory.first {
                $0.relativePath == "Frameworks/FatFixture"
            }?.sha256,
            directFat.fileSHA256
        )
        XCTAssertEqual(try Data(contentsOf: thinURL), thinBytesBefore)
        XCTAssertEqual(try Data(contentsOf: fatURL), fatBytesBefore)
    }

    func testInspectAcceptsCodesignSelectedAlternateCodeDirectory()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverDualCodeDirectory-\(UUID().uuidString)",
                isDirectory: true
            )
        let executable = root.appendingPathComponent("DualCodeDirectory")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: executable
        )
        let codesign = Process()
        let output = Pipe()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force",
            "--sign",
            "-",
            "--digest-algorithm=sha1,sha256",
            executable.path,
        ]
        codesign.standardOutput = output
        codesign.standardError = output
        try codesign.run()
        let codesignOutput =
            try output.fileHandleForReading.readToEnd() ?? Data()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            return XCTFail(
                String(data: codesignOutput, encoding: .utf8)
                    ?? "codesign failed without UTF-8 output"
            )
        }

        let inspection = try PlayCoverUpstreamEngine.inspectMachO(
            at: executable,
            relativePath: executable.lastPathComponent
        )
        let arm64 = try XCTUnwrap(
            inspection.allSlices.first {
                $0.cpuType == Int32(bitPattern: 0x0100_000c)
            }
        )
        let primary = try XCTUnwrap(
            arm64.signature.embeddedSlots.first {
                $0.type == 0
            }?.codeDirectory
        )
        let alternate = try XCTUnwrap(
            arm64.signature.embeddedSlots.first {
                $0.type == 0x1_000
            }?.codeDirectory
        )

        XCTAssertEqual(primary.hashType, 1)
        XCTAssertEqual(alternate.hashType, 2)
        XCTAssertNotEqual(primary.cdHash, alternate.cdHash)
        XCTAssertEqual(arm64.signature.cdHash, alternate.cdHash)
    }

    func testRuntimeBuildHashPreservesExistingFramedContract() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "IOSUsePlayCoverRuntimeHash-\(UUID().uuidString)",
                isDirectory: true
            )
        let first = root.appendingPathComponent(
            "First.framework",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            "Second.framework",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try makeHashFixture(at: first)
        try makeHashFixture(at: second)

        let firstHash = try PlayCoverUpstreamEngine.runtimeBuildHash(
            frameworkURL: first
        )
        XCTAssertEqual(
            firstHash,
            "94382213f0d069d49c9e2850fa76171b9899c1391b6e18fd1144336a613f1814"
        )
        XCTAssertEqual(
            firstHash,
            try PlayCoverUpstreamEngine.runtimeBuildHash(
                frameworkURL: second
            ),
            "the Runtime framework root path must not enter its build hash"
        )
    }

    func testRuntimeBuildHashSurvivesCopyAcrossPathAliases() throws {
        let lexicalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverRuntimeCopy-\(UUID().uuidString)",
                isDirectory: true
            )
        let canonicalRoot = lexicalRoot.resolvingSymlinksInPath()
        let source = canonicalRoot.appendingPathComponent(
            "Source.framework",
            isDirectory: true
        )
        let copy = lexicalRoot.appendingPathComponent(
            "Copy.framework",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        try makeHashFixture(at: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let sourceHash = try PlayCoverUpstreamEngine.runtimeBuildHash(
            frameworkURL: source
        )
        let copyHash = try PlayCoverUpstreamEngine.runtimeBuildHash(
            frameworkURL: copy
        )
        XCTAssertEqual(
            sourceHash,
            copyHash,
            "copying through /tmp or /var aliases must preserve build identity"
        )
    }

    func testPrepareWithInspectionRejectsDifferentCanonicalSource() throws {
        let fixture = try makeInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverUpstreamEngine.inspect(
            appURL: fixture.app
        )
        let different = fixture.root.appendingPathComponent(
            "Different.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: fixture.app, to: different)
        let options = PlayCoverUpstreamPrepareOptions(
            sourceApp: different,
            stagingApp: fixture.root.appendingPathComponent(
                "Staging.app",
                isDirectory: true
            ),
            runtimeFramework: fixture.root.appendingPathComponent(
                "Missing.framework",
                isDirectory: true
            ),
            managedHome: fixture.root.appendingPathComponent(
                "home",
                isDirectory: true
            ),
            runtimeSocketPath: "/tmp/unused.sock",
            runtimeLoadPath: "@rpath/Unused.framework/Unused"
        )

        XCTAssertThrowsError(
            try PlayCoverUpstreamEngine.prepare(
                options,
                sourceInspection: inspection
            )
        ) { error in
            guard case PlayCoverUpstreamError.invalidApp(let message) = error
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                message.contains("source inspection path"),
                message
            )
        }
    }

    private struct InspectionFixture {
        let root: URL
        let app: URL
    }

    private func makeHashFixture(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let a = root.appendingPathComponent("A.txt")
        let z = root.appendingPathComponent("z.bin")
        try Data("alpha".utf8).write(to: a)
        try Data([0, 1, 2, 3]).write(to: z)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: a.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: z.path
        )
    }

    private func makeInspectionFixture() throws -> InspectionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverUpstreamInspect-\(UUID().uuidString)",
                isDirectory: true
            )
        let app = root.appendingPathComponent(
            "Fixture.app",
            isDirectory: true
        )
        let frameworks = app.appendingPathComponent(
            "Frameworks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworks,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.upstream-inspection",
            "CFBundleExecutable": "Fixture",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))

        let arm64 = makeThinMachO(
            cpuType: 0x0100_000c,
            cpuSubtype: 0,
            platform: 2
        )
        let x86 = makeThinMachO(
            cpuType: 0x0100_0007,
            cpuSubtype: 3,
            platform: 7
        )
        let thin = app.appendingPathComponent("Fixture")
        let fat = frameworks.appendingPathComponent("FatFixture")
        try arm64.write(to: thin)
        try makeFatMachO(arm64: arm64, x86_64: x86).write(to: fat)
        for executable in [thin, fat] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return InspectionFixture(root: root, app: app)
    }

    private func makeThinMachO(
        cpuType: UInt32,
        cpuSubtype: UInt32,
        platform: UInt32
    ) -> Data {
        var segment = Data()
        appendU32LE(0x19, to: &segment)
        appendU32LE(152, to: &segment)
        segment.append(Data(repeating: 0, count: 56))
        appendU32LE(1, to: &segment)
        appendU32LE(0, to: &segment)
        segment.append(Data(repeating: 0, count: 48))
        appendU32LE(512, to: &segment)
        segment.append(Data(repeating: 0, count: 28))

        var build = Data()
        appendU32LE(0x32, to: &build)
        appendU32LE(24, to: &build)
        appendU32LE(platform, to: &build)
        appendU32LE(0x0011_0000, to: &build)
        appendU32LE(0x0011_0400, to: &build)
        appendU32LE(0, to: &build)

        let commands = [segment, build]
        var result = Data([0xcf, 0xfa, 0xed, 0xfe])
        appendU32LE(cpuType, to: &result)
        appendU32LE(cpuSubtype, to: &result)
        appendU32LE(2, to: &result)
        appendU32LE(UInt32(commands.count), to: &result)
        appendU32LE(
            UInt32(commands.reduce(0) { $0 + $1.count }),
            to: &result
        )
        appendU32LE(0, to: &result)
        appendU32LE(0, to: &result)
        for command in commands {
            result.append(command)
        }
        result.append(
            Data(repeating: 0, count: max(0, 512 - result.count))
        )
        result.append(Data(repeating: 0xab, count: 64))
        return result
    }

    private func makeFatMachO(arm64: Data, x86_64: Data) -> Data {
        let arm64Offset = 4_096
        let x86Offset = aligned(arm64Offset + arm64.count, to: 4_096)
        var result = Data([0xca, 0xfe, 0xba, 0xbe])
        appendU32BE(2, to: &result)
        appendU32BE(0x0100_000c, to: &result)
        appendU32BE(0, to: &result)
        appendU32BE(UInt32(arm64Offset), to: &result)
        appendU32BE(UInt32(arm64.count), to: &result)
        appendU32BE(12, to: &result)
        appendU32BE(0x0100_0007, to: &result)
        appendU32BE(3, to: &result)
        appendU32BE(UInt32(x86Offset), to: &result)
        appendU32BE(UInt32(x86_64.count), to: &result)
        appendU32BE(12, to: &result)
        result.append(
            Data(repeating: 0, count: arm64Offset - result.count)
        )
        result.append(arm64)
        result.append(
            Data(repeating: 0, count: x86Offset - result.count)
        )
        result.append(x86_64)
        return result
    }

    private func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }

    private func appendU32LE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    private func appendU32BE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }
}
