import XCTest
import IOSUseCLI
import IOSUseProtocol

final class DriverOutputTests: XCTestCase {
    func testFormatFindIncludesValueText() {
        let payload = ForyFindPayload(matches: [
            ForyFindMatch(elemType: 10, label: "First name", rect: ForyRect(x: 1, y: 2, w: 3, h: 4), traits: ["TextField"], value: "Alpha")
        ])

        let output = DriverOutput.formatFind(label: "Alpha", payload: payload)

        XCTAssertTrue(output.contains("Find \"Alpha\""))
        XCTAssertTrue(output.contains("TextField \"First name=Alpha\""))
    }
}
