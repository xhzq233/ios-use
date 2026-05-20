import Foundation
import IOSUseDaemonRuntime

let rawArguments = Array(CommandLine.arguments.dropFirst())
if rawArguments.first == "__daemon" {
    Foundation.exit(DaemonProcess().run())
}

let result: CLIResult
switch rawArguments.first {
case nil, "-h", "--help", "help":
    result = CLIResult(exitCode: 0, stdout: IOSUseCLI.helpText)
case "-V", "--version":
    result = CLIResult(exitCode: 0, stdout: "\(IOSUseCLI.version)\n")
default:
    if rawArguments.dropFirst().contains("--help") || rawArguments.dropFirst().contains("-h") {
        result = CLIResult(exitCode: 0, stdout: IOSUseCLI.helpText)
    } else {
        result = DaemonFrontend().run(
            arguments: rawArguments,
            executablePath: CommandLine.arguments[0]
        )
    }
}

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}

Foundation.exit(result.exitCode)
