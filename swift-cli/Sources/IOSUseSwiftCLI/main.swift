import Foundation
import IOSUseCLI

let arguments = Array(CommandLine.arguments.dropFirst())
let cli = IOSUseCLI(
    outputSink: { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    },
    registerHomesForDiskUsage: true
)
let result = cli.run(arguments: arguments)

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}

if let reminder = UpdateReminderService.reminder(arguments: arguments, result: result, paths: cli.paths) {
    FileHandle.standardError.write(Data(reminder.utf8))
}

Foundation.exit(result.exitCode)
