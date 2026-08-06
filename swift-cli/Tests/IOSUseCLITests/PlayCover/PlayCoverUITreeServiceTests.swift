import XCTest
@testable import IOSUseCLI

final class PlayCoverUITreeServiceTests: XCTestCase {
    func testRunRejectsAnActiveNonMacSessionBeforeRuntimeWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-ui-tree-non-mac-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root.path]
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-DEVICE",
                deviceName: "iPhone",
                deviceVersion: "18.0",
                deviceType: "real"
            ),
            paths: paths
        )

        XCTAssertThrowsError(
            try PlayCoverUITreeService.run(
                options: UITreeOptions(),
                paths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? PlayCoverUITreeService.Error,
                .requiresMacSession
            )
            XCTAssertEqual(
                (error as? PlayCoverUITreeService.Error)?
                    .machineError.code,
                "mac_session_required"
            )
        }
    }

    func testHumanAndMachineOutputKeepHierarchyAndUsefulProperties() throws {
        let child = makeNode(
            id: "v0.0",
            path: [0, 0],
            depth: 1,
            index: 0,
            className: "UILabel",
            label: "导入照片",
            properties: [
                "text": .string("导入照片"),
                "fontSize": .number(18),
            ]
        )
        let image = makeNode(
            id: "v0.1",
            path: [0, 1],
            depth: 1,
            index: 1,
            className: "UIImageView",
            clipsToBounds: true,
            contentMode: "scaleAspectFill",
            properties: ["image": .null]
        )
        let root = makeNode(
            id: "v0",
            path: [0],
            depth: 0,
            index: 0,
            className: "UIView",
            subviews: [child, image]
        )
        let payload = PlayCoverRuntimeUITreePayload(
            source: "uikit-view-hierarchy",
            target: "导入照片",
            maxDepth: 8,
            nodeCount: 3,
            truncated: false,
            roots: [root]
        )

        let text = PlayCoverUITreeService.format(payload)
        XCTAssertTrue(text.contains("UIKit view tree · 3 nodes"))
        XCTAssertTrue(text.contains("Target: 导入照片"))
        XCTAssertTrue(text.contains("└─ UIView v0"))
        XCTAssertTrue(text.contains("UILabel v0.0"))
        XCTAssertTrue(text.contains("fontSize=18"))
        XCTAssertTrue(text.contains("contentMode=scaleAspectFill"))
        XCTAssertTrue(text.contains(" clips"))

        let machine = PlayCoverUITreeService.machineData(payload)
        let encoded = try JSONEncoder().encode(machine)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        XCTAssertEqual(object["source"] as? String, "uikit-view-hierarchy")
        XCTAssertEqual(object["nodeCount"] as? Int, 3)
        let roots = try XCTUnwrap(object["roots"] as? [[String: Any]])
        let subviews = try XCTUnwrap(
            roots[0]["subviews"] as? [[String: Any]]
        )
        XCTAssertEqual(subviews[0]["class"] as? String, "UILabel")
        XCTAssertNil(subviews[0]["address"])
        XCTAssertEqual(subviews[1]["class"] as? String, "UIImageView")
    }

    func testHumanOutputSurfacesTruncation() {
        let payload = PlayCoverRuntimeUITreePayload(
            source: "uikit-view-hierarchy",
            target: nil,
            maxDepth: 0,
            nodeCount: 1,
            truncated: true,
            roots: [makeNode()]
        )

        XCTAssertTrue(
            PlayCoverUITreeService.format(payload)
                .contains("output truncated by the depth or node limit")
        )
    }

    func testHumanOutputPrintsViewControllerOnlyWhenItChanges() {
        let child = makeNode(
            id: "v0.0",
            path: [0, 0],
            depth: 1,
            viewControllerClass: "FixtureViewController"
        )
        let root = makeNode(
            viewControllerClass: "FixtureViewController",
            subviews: [child]
        )
        let payload = PlayCoverRuntimeUITreePayload(
            source: "uikit-view-hierarchy",
            target: nil,
            maxDepth: 8,
            nodeCount: 2,
            truncated: false,
            roots: [root]
        )

        let text = PlayCoverUITreeService.format(payload)
        XCTAssertEqual(
            text.components(separatedBy: "vc=FixtureViewController").count - 1,
            1
        )
    }

    private func makeNode(
        id: String = "v0",
        path: [Int] = [0],
        depth: Int = 0,
        index: Int = 0,
        className: String = "UIView",
        viewControllerClass: String? = nil,
        label: String? = nil,
        clipsToBounds: Bool = false,
        contentMode: String = "scaleToFill",
        properties: [String: PlayCoverRuntimeJSONValue] = [:],
        subviews: [PlayCoverRuntimeUITreeNode] = []
    ) -> PlayCoverRuntimeUITreeNode {
        PlayCoverRuntimeUITreeNode(
            nodeID: id,
            path: path,
            depth: depth,
            index: index,
            childCount: subviews.count,
            class: className,
            viewControllerClass: viewControllerClass,
            frame: .init(x: 1, y: 2, width: 100, height: 30),
            bounds: .init(x: 0, y: 0, width: 100, height: 30),
            hidden: false,
            alpha: 1,
            userInteractionEnabled: true,
            clipsToBounds: clipsToBounds,
            contentMode: contentMode,
            accessibilityIdentifier: nil,
            accessibilityLabel: label,
            layout: .init(
                ambiguous: false,
                translatesAutoresizingMaskIntoConstraints: false,
                constraintCount: 0
            ),
            properties: properties,
            subviews: subviews
        )
    }
}
