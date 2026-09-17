import Foundation
import IOSUsePlayDevice

struct PlayCoverDevicePreset: Equatable {
    let name: String
    let productType: String
    let logicalSize: CGSize
    let scale: Double
    var nativeSize: CGSize {
        CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
    }

    static let presets: [Self] = {
        var result: [Self] = []
        var index: Int32 = 0
        while let pointer = IOSUsePlayDevicePresetAt(index) {
            let value = pointer.pointee
            result.append(Self(name: String(cString: value.name),
                               productType: String(cString: value.productType),
                               logicalSize: CGSize(width: Int(value.logicalWidth), height: Int(value.logicalHeight)),
                               scale: Double(value.scale)))
            index += 1
        }
        return result
    }()
    static let defaultPreset = presets[0]

    static func named(_ name: String) throws -> Self {
        let resolvedName = name == "iphone-duo" ? "iphone-duo-inner" : name
        guard let preset = presets.first(where: { $0.name == resolvedName }) else {
            let names = presets.filter { $0.name != "iphone-duo-outer" }
                .map { $0.name == "iphone-duo-inner" ? "iphone-duo" : $0.name }
            throw CLIParseError.invalidValue("Unknown Mac device preset \(name). Available: \(names.joined(separator: ", "))")
        }
        return name == "iphone-duo" ? Self(name: "iphone-duo", productType: preset.productType, logicalSize: preset.logicalSize, scale: preset.scale) : preset
    }

    static func configured(paths: IOSUsePaths) throws -> Self {
        let path = URL(fileURLWithPath: paths.playcover).appendingPathComponent("device.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return defaultPreset }
        let value = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: path))
        return try named(value.preset)
    }

    func save(paths: IOSUsePaths) throws {
        let directory = URL(fileURLWithPath: paths.playcover)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var selection = try Selection.load(paths: paths)
        selection.preset = name
        try selection.save(paths: paths)
    }

    var machineData: MachineValue {
        .object(["preset": .string(name), "productType": .string(productType),
                 "layoutPreview": .boolean(name.hasPrefix("iphone-duo")),
                 "logicalWidth": .integer(Int(logicalSize.width)),
                 "logicalHeight": .integer(Int(logicalSize.height)), "scale": .integer(Int(scale))])
    }

    struct Selection: Codable {
        var preset: String
        var chrome: String? = nil
        var windowMode: String? = nil
        var orientation: String? = nil
        var expanded: Bool? = nil

        static func load(paths: IOSUsePaths) throws -> Self {
            let file = URL(fileURLWithPath: paths.playcover).appendingPathComponent("device.json")
            guard FileManager.default.fileExists(atPath: file.path) else {
                return Self(preset: PlayCoverDevicePreset.defaultPreset.name)
            }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }
        func save(paths: IOSUsePaths) throws {
            let directory = URL(fileURLWithPath: paths.playcover)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("device.json"), options: .atomic)
        }
    }
}
