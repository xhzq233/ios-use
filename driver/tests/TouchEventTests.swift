import UIKit
import XCTest

final class TouchEventTests: XCTestCase {
    func testTouchRecordsKeepEachInterfaceOrientationWithoutDispatching() throws {
        for orientation in [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            var error: NSError?
            let record = try XCTUnwrap(XCMakeTouchEventRecord(CGPoint(x: 140, y: 315), 0.08,
                "Tap", orientation.rawValue, &error) as? NSObject)
            XCTAssertNil(error)
            XCTAssertEqual((record.value(forKey: "interfaceOrientation") as? NSNumber)?.intValue, orientation.rawValue)
            XCTAssertEqual((record.value(forKey: "eventPaths") as? [Any])?.count, 1)
        }
    }

    func testOrientedLongPressKeepsItsHoldDuration() throws {
        var error: NSError?
        let record = try XCTUnwrap(XCMakeTouchEventRecord(CGPoint(x: 140, y: 315), 0.6,
            "Long Press", UIInterfaceOrientation.landscapeRight.rawValue, &error) as? NSObject)
        XCTAssertNil(error)
        XCTAssertEqual(try XCTUnwrap(record.value(forKey: "maximumOffset") as? NSNumber).doubleValue, 0.6, accuracy: 0.001)
    }
}
