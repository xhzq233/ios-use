import Foundation

enum ArtifactPaths {
    static func file(paths: IOSUsePaths, name: String?, defaultName: String, extension ext: String) throws -> String {
        let safeName = try safeArtifactName(name, defaultName: defaultName)
        return URL(fileURLWithPath: paths.artifacts, isDirectory: true)
            .appendingPathComponent("\(safeName).\(ext)", isDirectory: false)
            .standardized
            .path
    }

    static func safeArtifactName(_ name: String?, defaultName: String) throws -> String {
        let raw = (name?.isEmpty == false ? name! : defaultName).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacedSeparators = raw
            .replacingOccurrences(of: #"[\\/]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !replacedSeparators.isEmpty else {
            throw CLIParseError.invalidValue("artifact name must contain at least one safe character")
        }
        return replacedSeparators
    }
}
