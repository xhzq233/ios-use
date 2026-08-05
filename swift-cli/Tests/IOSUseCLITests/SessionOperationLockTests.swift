import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class SessionOperationLockTests: XCTestCase {
    func testHardlinkedLockIsRejectedWithoutChangingVictimMode()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-operation-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root.path]
        )

        try SessionOperationLock.withExclusiveLock(paths: paths) {}
        let lockURL = URL(fileURLWithPath: paths.playcover)
            .appendingPathComponent("operation.lock")
        try FileManager.default.removeItem(at: lockURL)

        let victim = root.appendingPathComponent("victim")
        try Data("keep-me".utf8).write(to: victim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: victim.path
        )
        XCTAssertEqual(
            Darwin.link(victim.path, lockURL.path),
            0,
            "hardlink fixture failed with errno \(errno)"
        )

        XCTAssertThrowsError(
            try SessionOperationLock.withExclusiveLock(paths: paths) {}
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("singly-linked"),
                String(describing: error)
            )
        }

        var victimStatus = stat()
        XCTAssertEqual(Darwin.lstat(victim.path, &victimStatus), 0)
        XCTAssertEqual(victimStatus.st_mode & 0o7777, 0o644)
        XCTAssertEqual(victimStatus.st_nlink, 2)
        XCTAssertEqual(
            try Data(contentsOf: victim),
            Data("keep-me".utf8)
        )
    }
}
