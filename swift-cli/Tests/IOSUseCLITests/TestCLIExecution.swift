import Foundation
import IOSUseDaemonRuntime

func executeTestCLI(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String]
) -> CLIResult {
    do {
        let parsed = try CLIParser.parse(arguments)
        return IOSUseCLI(environment: environment).executeParsed(parsed)
    } catch let error as CLIParseError {
        return CLIErrorEnvelope(message: error.description).render()
    } catch {
        return CLIErrorEnvelope(message: "\(error)").render()
    }
}
