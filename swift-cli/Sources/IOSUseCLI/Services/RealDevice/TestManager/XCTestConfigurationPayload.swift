import Foundation
import IOSUseProtocol

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

        let testBundleURL = try builder.nsURL(relative: URL(fileURLWithPath: testBundlePath).absoluteString)
        let sessionUUID = try builder.nsUUID(sessionIdentifier)
        let formatVersion = builder.append(NSNumber(value: IOSUseProtocol.XCConstants.xctestConfigurationFormatVersion))
        let targetBundle = targetApplicationBundleID.map { builder.append($0 as NSString) } ?? 0
        let targetPath = builder.append((targetApplicationPath ?? IOSUseProtocol.XCConstants.xctestConfigurationFallbackTargetAppPath) as NSString)
        let automationPath = builder.append(IOSUseProtocol.XCConstants.xctestAutomationFrameworkPath as NSString)
        let productModule = productModuleName.map { builder.append($0 as NSString) } ?? 0
        let suiteRecords = try builder.nsDictionary([:])
        let aggregateStats = try builder.nsDictionary(["XCSuiteRecordsKey": suiteRecords])
        let emptyArray = try builder.nsArray([])
        let emptyDictionary = try builder.nsDictionary([:])
        let configClass = builder.classObject("XCTestConfiguration", "NSObject")

        builder.replace(at: rootIndex, with: [
            "testBundleURL": try builder.uid(testBundleURL),
            "sessionIdentifier": try builder.uid(sessionUUID),
            "formatVersion": try builder.uid(formatVersion),
            "treatMissingBaselinesAsFailures": false,
            "targetApplicationBundleID": try builder.uid(targetBundle),
            "targetApplicationPath": try builder.uid(targetPath),
            "reportResultsToIDE": true,
            "automationFrameworkPath": try builder.uid(automationPath),
            "testsMustRunOnMainThread": true,
            "initializeForUITesting": true,
            "reportActivities": true,
            "testsToSkip": try builder.uid(0),
            "testsToRun": try builder.uid(0),
            "productModuleName": try builder.uid(productModule),
            "testBundleRelativePath": try builder.uid(0),
            "aggregateStatisticsBeforeCrash": try builder.uid(aggregateStats),
            "baselineFileRelativePath": try builder.uid(0),
            "baselineFileURL": try builder.uid(0),
            "defaultTestExecutionTimeAllowance": try builder.uid(0),
            "disablePerformanceMetrics": false,
            "emitOSLogs": false,
            "gatherLocalizableStringsData": false,
            "maximumTestExecutionTimeAllowance": try builder.uid(0),
            "randomExecutionOrderingSeed": try builder.uid(0),
            "systemAttachmentLifetime": IOSUseProtocol.XCConstants.xctestSystemAttachmentLifetime,
            "targetApplicationArguments": try builder.uid(emptyArray),
            "targetApplicationEnvironment": try builder.uid(0),
            "testApplicationDependencies": try builder.uid(emptyDictionary),
            "testApplicationUserOverrides": try builder.uid(0),
            "testExecutionOrdering": 0,
            "testTimeoutsEnabled": false,
            "testsDrivenByIDE": false,
            "userAttachmentLifetime": IOSUseProtocol.XCConstants.xctestUserAttachmentLifetime,
            "$class": try builder.uid(configClass),
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
        let capabilitiesDictionary = try builder.nsDictionary(capabilityEntries)
        let capabilitiesClass = builder.classObject("XCTCapabilities", "NSObject")
        builder.replace(at: rootIndex, with: [
            "capabilities-dictionary": try builder.uid(capabilitiesDictionary),
            "$class": try builder.uid(capabilitiesClass),
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

    func uid(_ index: Int) throws -> Any {
        try KeyedArchiveUID.value(index)
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

    mutating func nsURL(relative: String) throws -> Int {
        let relativeIndex = append(relative as NSString)
        let classIndex = classObject("NSURL", "NSObject")
        return try append([
            "NS.base": uid(0),
            "NS.relative": uid(relativeIndex),
            "$class": uid(classIndex),
        ])
    }

    mutating func nsUUID(_ uuid: UUID) throws -> Int {
        let classIndex = classObject("NSUUID", "NSObject")
        return try append([
            "NS.uuidbytes": Data(uuid.uuidString.replacingOccurrences(of: "-", with: "").hexBytes()),
            "$class": uid(classIndex),
        ])
    }

    mutating func nsArray(_ objectIndexes: [Int]) throws -> Int {
        let classIndex = classObject("NSArray", "NSObject")
        return try append([
            "NS.objects": objectIndexes.map { try uid($0) },
            "$class": uid(classIndex),
        ])
    }

    mutating func nsDictionary(_ entries: [String: Int]) throws -> Int {
        let classIndex = classObject("NSDictionary", "NSObject")
        let sorted = entries.sorted { $0.key < $1.key }
        let keyIndexes = sorted.map { append($0.key as NSString) }
        return try append([
            "NS.keys": keyIndexes.map { try uid($0) },
            "NS.objects": sorted.map { try uid($0.value) },
            "$class": uid(classIndex),
        ])
    }

    func archive(rootIndex: Int) throws -> Data {
        let plist = try archivePlist(rootIndex: rootIndex)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func archivePlist(rootIndex: Int) throws -> [String: Any] {
        [
            "$version": IOSUseProtocol.XCConstants.nsKeyedArchiveVersion,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": try uid(rootIndex)],
            "$objects": objects,
        ]
    }
}

private enum KeyedArchiveUID {
    private static let maxUID = IOSUseProtocol.XCConstants.nsKeyedArchiveMaxUID
    private static let values = Result<[Any], Error> {
        try makeValues()
    }

    static func value(_ index: Int) throws -> Any {
        let values = try values.get()
        guard index >= 0 && index < values.count else {
            throw CLIParseError.invalidValue("NSKeyedArchiver UID index out of range: \(index)")
        }
        return values[index]
    }

    private static func makeValues() throws -> [Any] {
        var result = Array<Any?>(repeating: nil, count: maxUID)

        guard let probeURL = NSURL(string: "file:///tmp/ios-use-uid-probe") else {
            throw CLIParseError.invalidValue("failed to construct NSKeyedArchiver UID probe URL")
        }
        let urlData = try NSKeyedArchiver.archivedData(
            withRootObject: probeURL,
            requiringSecureCoding: false
        )
        let urlArchiveAny = try PropertyListSerialization.propertyList(from: urlData, options: [], format: nil)
        guard let urlArchive = urlArchiveAny as? [String: Any],
              let urlObjects = urlArchive["$objects"] as? [Any],
              urlObjects.indices.contains(1),
              let urlObject = urlObjects[1] as? [String: Any],
              let baseUID = urlObject["NS.base"] else {
            throw CLIParseError.invalidValue("failed to derive NSKeyedArchiver URL base UID")
        }
        result[0] = baseUID

        let arrayData = try NSKeyedArchiver.archivedData(
            withRootObject: (0..<(maxUID - 2)).map { NSNumber(value: $0) } as NSArray,
            requiringSecureCoding: false
        )
        let arrayArchiveAny = try PropertyListSerialization.propertyList(from: arrayData, options: [], format: nil)
        guard let arrayArchive = arrayArchiveAny as? [String: Any],
              let top = arrayArchive["$top"] as? [String: Any],
              let rootUID = top["root"],
              let arrayObjects = arrayArchive["$objects"] as? [Any],
              arrayObjects.indices.contains(1),
              let arrayObject = arrayObjects[1] as? [String: Any],
              let refs = arrayObject["NS.objects"] as? [Any] else {
            throw CLIParseError.invalidValue("failed to derive NSKeyedArchiver array UID table")
        }
        result[1] = rootUID
        for (offset, ref) in refs.enumerated() {
            let value = offset + 2
            if value < result.count {
                result[value] = ref
            }
        }

        var values: [Any] = []
        values.reserveCapacity(result.count)
        for (index, value) in result.enumerated() {
            guard let value else {
                throw CLIParseError.invalidValue("missing NSKeyedArchiver UID probe value at index \(index)")
            }
            values.append(value)
        }
        return values
    }
}

private extension String {
    func hexBytes() throws -> [UInt8] {
        guard count % 2 == 0 else {
            throw CLIParseError.invalidValue("hex string has odd length")
        }
        var output: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            guard let byte = UInt8(self[index..<next], radix: 16) else {
                throw CLIParseError.invalidValue("invalid hex byte '\(self[index..<next])'")
            }
            output.append(byte)
            index = next
        }
        return output
    }
}
