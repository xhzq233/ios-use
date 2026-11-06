import Foundation

// Shared protocol sources report validation errors without importing CLI UI.
enum CLIParseError: Error, CustomStringConvertible {
    case invalidValue(String)
    var description: String { switch self { case .invalidValue(let text): return text } }
}
