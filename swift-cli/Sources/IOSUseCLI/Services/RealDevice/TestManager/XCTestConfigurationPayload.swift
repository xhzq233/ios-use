import Foundation

struct XCTestConfigurationPayload: Equatable {
    let testBundlePath: String
    let sessionIdentifier: UUID
    let targetApplicationBundleID: String?
    let targetApplicationPath: String?
    let productModuleName: String?

    init(
        testBundlePath: String,
        sessionIdentifier: UUID,
        targetApplicationBundleID: String? = nil,
        targetApplicationPath: String? = nil,
        productModuleName: String? = nil
    ) {
        self.testBundlePath = testBundlePath
        self.sessionIdentifier = sessionIdentifier
        self.targetApplicationBundleID = targetApplicationBundleID
        self.targetApplicationPath = targetApplicationPath
        self.productModuleName = productModuleName
    }

    func encode() throws -> Data {
        var builder = NSKeyedArchiveBuilder()
        let rootIndex = builder.reserve()

        let testBundleURL = builder.nsURL(relative: URL(fileURLWithPath: testBundlePath).absoluteString)
        let sessionUUID = builder.nsUUID(sessionIdentifier)
        let formatVersion = builder.append(NSNumber(value: 2))
        let targetBundle = targetApplicationBundleID.map { builder.append($0 as NSString) } ?? 0
        let targetPath = builder.append((targetApplicationPath ?? "/tmp/XCTestTargetApp.app") as NSString)
        let automationPath = builder.append("/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework" as NSString)
        let productModule = productModuleName.map { builder.append($0 as NSString) } ?? 0
        let aggregateStats = builder.nsDictionary(["XCSuiteRecordsKey": builder.nsDictionary([:])])
        let emptyArray = builder.nsArray([])
        let emptyDictionary = builder.nsDictionary([:])
        let configClass = builder.classObject("XCTestConfiguration", "NSObject")

        builder.replace(at: rootIndex, with: [
            "testBundleURL": builder.uid(testBundleURL),
            "sessionIdentifier": builder.uid(sessionUUID),
            "formatVersion": builder.uid(formatVersion),
            "treatMissingBaselinesAsFailures": false,
            "targetApplicationBundleID": builder.uid(targetBundle),
            "targetApplicationPath": builder.uid(targetPath),
            "reportResultsToIDE": true,
            "automationFrameworkPath": builder.uid(automationPath),
            "testsMustRunOnMainThread": true,
            "initializeForUITesting": true,
            "reportActivities": true,
            "testsToSkip": builder.uid(0),
            "testsToRun": builder.uid(0),
            "productModuleName": builder.uid(productModule),
            "testBundleRelativePath": builder.uid(0),
            "aggregateStatisticsBeforeCrash": builder.uid(aggregateStats),
            "baselineFileRelativePath": builder.uid(0),
            "baselineFileURL": builder.uid(0),
            "defaultTestExecutionTimeAllowance": builder.uid(0),
            "disablePerformanceMetrics": false,
            "emitOSLogs": false,
            "gatherLocalizableStringsData": false,
            "maximumTestExecutionTimeAllowance": builder.uid(0),
            "randomExecutionOrderingSeed": builder.uid(0),
            "systemAttachmentLifetime": 2,
            "targetApplicationArguments": builder.uid(emptyArray),
            "targetApplicationEnvironment": builder.uid(0),
            "testApplicationDependencies": builder.uid(emptyDictionary),
            "testApplicationUserOverrides": builder.uid(0),
            "testExecutionOrdering": 0,
            "testTimeoutsEnabled": false,
            "testsDrivenByIDE": false,
            "userAttachmentLifetime": 1,
            "$class": builder.uid(configClass),
        ])

        return try builder.archive(rootIndex: rootIndex)
    }
}

enum XCTestCapabilitiesPayload {
    static func encode(_ capabilities: [String: Int]) throws -> Data {
        var builder = NSKeyedArchiveBuilder()
        let rootIndex = builder.reserve()
        let capabilityEntries = capabilities.reduce(into: [String: Int]()) { result, item in
            result[item.key] = builder.append(NSNumber(value: item.value))
        }
        let capabilitiesDictionary = builder.nsDictionary(capabilityEntries)
        let capabilitiesClass = builder.classObject("XCTCapabilities", "NSObject")
        builder.replace(at: rootIndex, with: [
            "capabilities-dictionary": builder.uid(capabilitiesDictionary),
            "$class": builder.uid(capabilitiesClass),
        ])
        return try builder.archive(rootIndex: rootIndex)
    }
}

private struct NSKeyedArchiveBuilder {
    private var objects: [Any] = ["$null"]
    private var classIndexes: [String: Int] = [:]

    mutating func reserve() -> Int {
        append(NSNull())
    }

    mutating func replace(at index: Int, with object: Any) {
        objects[index] = object
    }

    mutating func append(_ object: Any) -> Int {
        objects.append(object)
        return objects.count - 1
    }

    func uid(_ index: Int) -> Any {
        KeyedArchiveUID.value(index)
    }

    mutating func classObject(_ classname: String, _ superclasses: String...) -> Int {
        if let existing = classIndexes[classname] {
            return existing
        }
        let index = append([
            "$classes": [classname] + superclasses,
            "$classname": classname,
        ])
        classIndexes[classname] = index
        return index
    }

    mutating func nsURL(relative: String) -> Int {
        let relativeIndex = append(relative as NSString)
        let classIndex = classObject("NSURL", "NSObject")
        return append([
            "NS.base": uid(0),
            "NS.relative": uid(relativeIndex),
            "$class": uid(classIndex),
        ])
    }

    mutating func nsUUID(_ uuid: UUID) -> Int {
        let classIndex = classObject("NSUUID", "NSObject")
        return append([
            "NS.uuidbytes": Data(uuid.uuidString.replacingOccurrences(of: "-", with: "").hexBytes),
            "$class": uid(classIndex),
        ])
    }

    mutating func nsArray(_ objectIndexes: [Int]) -> Int {
        let classIndex = classObject("NSArray", "NSObject")
        return append([
            "NS.objects": objectIndexes.map { uid($0) },
            "$class": uid(classIndex),
        ])
    }

    mutating func nsDictionary(_ entries: [String: Int]) -> Int {
        let classIndex = classObject("NSDictionary", "NSObject")
        let sorted = entries.sorted { $0.key < $1.key }
        let keyIndexes = sorted.map { append($0.key as NSString) }
        return append([
            "NS.keys": keyIndexes.map { uid($0) },
            "NS.objects": sorted.map { uid($0.value) },
            "$class": uid(classIndex),
        ])
    }

    func archive(rootIndex: Int) throws -> Data {
        let plist = try archivePlist(rootIndex: rootIndex)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func archivePlist(rootIndex: Int) throws -> [String: Any] {
        [
            "$version": 100_000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": uid(rootIndex)],
            "$objects": objects,
        ]
    }
}

private enum KeyedArchiveUID {
    private static let maxUID = 512
    private static let values: [Any] = makeValues()

    static func value(_ index: Int) -> Any {
        precondition(index >= 0 && index < values.count, "NSKeyedArchiver UID index out of range: \(index)")
        return values[index]
    }

    private static func makeValues() -> [Any] {
        var result = Array<Any?>(repeating: nil, count: maxUID)

        let urlData = try! NSKeyedArchiver.archivedData(
            withRootObject: NSURL(string: "file:///tmp/ios-use-uid-probe")!,
            requiringSecureCoding: false
        )
        let urlArchive = try! PropertyListSerialization.propertyList(from: urlData, options: [], format: nil) as! [String: Any]
        let urlObjects = urlArchive["$objects"] as! [Any]
        let urlObject = urlObjects[1] as! [String: Any]
        result[0] = urlObject["NS.base"]!

        let arrayData = try! NSKeyedArchiver.archivedData(
            withRootObject: (0..<(maxUID - 2)).map { NSNumber(value: $0) } as NSArray,
            requiringSecureCoding: false
        )
        let arrayArchive = try! PropertyListSerialization.propertyList(from: arrayData, options: [], format: nil) as! [String: Any]
        result[1] = (arrayArchive["$top"] as! [String: Any])["root"]!
        let arrayObjects = arrayArchive["$objects"] as! [Any]
        let arrayObject = arrayObjects[1] as! [String: Any]
        let refs = arrayObject["NS.objects"] as! [Any]
        for (offset, ref) in refs.enumerated() {
            let value = offset + 2
            if value < result.count {
                result[value] = ref
            }
        }

        return result.map { $0! }
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var output: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            output.append(UInt8(self[index..<next], radix: 16)!)
            index = next
        }
        return output
    }
}
