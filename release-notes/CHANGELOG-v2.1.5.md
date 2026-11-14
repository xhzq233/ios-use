# ios-use v2.1.5

- Fix Mac App termination through Command+Q and `stop`. Automatically clean up the matching session when the App exits, and recover confirmed-dead sessions on the next start.
- Speed up focused Mac text entry and add `input --replace --content ...` to replace or clear a native text field or text view in one command.
- Reject commands to an active Mac App whose Runtime no longer matches the CLI's installed resources. `status` reports when a restart is required, and `stop` remains available for recovery.
- Fix semantic taps on visible buttons and labels inside table and collection cells while retaining live hit testing, occlusion checks, and ambiguity rejection.
- Update the Skill to report ios-use defects proactively using available evidence, with a simpler bilingual feedback form.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

For each running Mac App, stop it and run
`ios-use start --mac --app <source.app>` to prepare it with the updated Runtime.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.5/scripts/install.sh | bash -s -- --version v2.1.5
```
