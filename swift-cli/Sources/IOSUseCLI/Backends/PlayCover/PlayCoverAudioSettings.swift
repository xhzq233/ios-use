import Foundation

struct PlayCoverAudioChanges: Codable, Equatable, Sendable {
    var volume: Int?
    var muted: Bool?
}

struct PlayCoverAudioState: Codable, Equatable, Sendable {
    var volume: Int
    var muted: Bool
    var outputCallbacks: Int? = nil
    var unsupportedOutputs: Int? = nil

    var machineData: MachineValue {
        .object(["volume": .integer(volume), "muted": .boolean(muted),
                 "effectiveVolume": .integer(muted ? 0 : volume),
                 "outputCallbacks": outputCallbacks.map(MachineValue.integer) ?? .null,
                 "unsupportedOutputs": unsupportedOutputs.map(MachineValue.integer) ?? .null])
    }
    var warnings: [String] {
        guard let count = unsupportedOutputs, count > 0 else { return [] }
        return ["\(count) audio output callback(s) use unsupported formats and remain unchanged."]
    }
    var description: String {
        "Mac App audio: volume \(volume)%, mute \(muted ? "on" : "off")."
            + warnings.map { " Warning: " + $0 }.joined()
    }

    static func load(file: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self(volume: 100, muted: true) }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard (0...100).contains(value.volume) else {
            throw CLIParseError.invalidValue("Saved Mac volume must be between 0 and 100")
        }
        return value
    }
    static func file(paths: IOSUsePaths) -> URL {
        URL(fileURLWithPath: paths.playcover).appendingPathComponent("audio.json")
    }
    func save(paths: IOSUsePaths) throws {
        let file = Self.file(paths: paths)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Callback diagnostics describe this process only, never persist them.
        try JSONEncoder().encode(Self(volume: volume, muted: muted)).write(to: file, options: .atomic)
    }
    static func configure(_ changes: PlayCoverAudioChanges, paths: IOSUsePaths) throws -> (state: Self, live: Bool) {
        if let context = DeviceContextStore.sessions(paths: paths).first(where: { $0.deviceID == "mac" }) {
            let client = try PlayCoverDriverClient.runtimeClient(for: context.info, timeoutSeconds: 8)
            guard case .configureAudio(let state) = try client.request(.configureAudio, arguments: .configureAudio(changes)) else {
                throw CLIParseError.invalidValue("Mac Runtime did not return its audio configuration")
            }
            try state.save(paths: paths)
            return (state, true)
        }
        var state = try load(file: file(paths: paths))
        if let volume = changes.volume { state.volume = volume }
        if let muted = changes.muted { state.muted = muted }
        try state.save(paths: paths)
        return (state, false)
    }
}
