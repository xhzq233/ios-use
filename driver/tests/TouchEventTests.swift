import UIKit
import XCTest

final class TouchEventTests: XCTestCase {
    func testTouchRecordsKeepEachInterfaceOrientationWithoutDispatching() throws {
        for orientation in [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            var error: NSError?
            let record = try XCTUnwrap(XCMakeTouchEventRecord(CGPoint(x: 140, y: 315), 0.08,
                "Tap", orientation.rawValue, nil, &error) as? NSObject)
            XCTAssertNil(error)
            XCTAssertEqual((record.value(forKey: "interfaceOrientation") as? NSNumber)?.intValue, orientation.rawValue)
            XCTAssertEqual((record.value(forKey: "eventPaths") as? [Any])?.count, 1)
        }
    }

    func testOrientedLongPressKeepsItsHoldDuration() throws {
        var error: NSError?
        let record = try XCTUnwrap(XCMakeTouchEventRecord(CGPoint(x: 140, y: 315), 0.6,
            "Long Press", UIInterfaceOrientation.landscapeRight.rawValue, nil, &error) as? NSObject)
        XCTAssertNil(error)
        XCTAssertEqual(try XCTUnwrap(record.value(forKey: "maximumOffset") as? NSNumber).doubleValue, 0.6, accuracy: 0.001)
    }

    func testTouchRecordKeepsExplicitDisplayAndOrientationThroughCoding() throws {
        for displayID in [UInt64(0), 3, 0x1_0000_0002] {
            var error: NSError?
            let record = try XCTUnwrap(XCMakeTouchEventRecord(CGPoint(x: 140, y: 315), 0.6,
                "Long Press", UIInterfaceOrientation.landscapeRight.rawValue, NSNumber(value: displayID), &error) as? NSObject)
            XCTAssertNil(error)
            let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClasses: [type(of: record)], from: data) as? NSObject)
            XCTAssertEqual((decoded.value(forKey: "displayID") as? NSNumber)?.uint64Value, displayID)
            XCTAssertEqual((decoded.value(forKey: "interfaceOrientation") as? NSNumber)?.intValue,
                           UIInterfaceOrientation.landscapeRight.rawValue)
            XCTAssertEqual((decoded.value(forKey: "eventPaths") as? [Any])?.count, 1)
            XCTAssertEqual(try XCTUnwrap(decoded.value(forKey: "maximumOffset") as? NSNumber).doubleValue, 0.6, accuracy: 0.001)
        }
    }
}
