# ios-use Report / GitHub Issue

Use this reference when an observed failure suggests an ios-use defect, or the
user asks to send feedback. Proactively report suspected defects to
[GitHub Issues](https://github.com/xhzq233/ios-use/issues); a complete reproduction
is helpful but is not required to accept a report.

## Rules

- Do not attach secrets: Apple ID, app-specific password, certificate/private-key material, full UDID, private app logs, tokens, or local account paths that identify people.
- Collect available evidence yourself: the command, error text, ios-use version,
  target backend and OS version, and relevant log excerpts. Mark unavailable
  details as unknown; do not ask the reporter to rebuild an environment or rerun
  a destructive or disruptive operation just to make the report complete.
- Prefer log tails over full logs. Start with 200-400 lines from the relevant files.
- Search open and closed issues for the same symptom before submitting. Add a
  comment to a matching issue when there is new evidence; do not post duplicate
  reports or repeat an existing comment without new information.
- Submit a sanitized report proactively, without a separate submit confirmation,
  unless the user has asked not to report. Review the actual report text before
  publishing; exclude private App content and raw artifacts. If useful details
  cannot be shared safely, report only the generic symptom and note the omission.
- Use the `gh` CLI first, or another available GitHub tool. If authentication or
  access is unavailable, save a sanitized draft and give the user the draft path
  and [web issue form](https://github.com/xhzq233/ios-use/issues/new/choose).
  State that submission did not succeed; do not stall the original task.
- Read logs under `${IOS_USE_HOME:-$HOME/.ios-use}/logs/devices/<device-id>/`.
  For `start`, inspect `xctest-holder.log` and `cli.log` when present. Older or
  host-level logs may also be under `logs/`; do not collect unrelated targets.
- If the issue is about proxy, include `ios-use proxy doctor` and proxy state, but do not include captured request bodies unless explicitly safe.

## Collect

Collect what is available on the current host and only the relevant log tails.
On Linux, skip `sw_vers`; include the host distribution and architecture instead.
Keep config/status output local until redacted:

```bash
ios-use --version
sw_vers
ios-use status
ios-use config --list
REPORT_HOME="${IOS_USE_HOME:-$HOME/.ios-use}"
# Set LOG_DIR to the affected target's log directory; read files that exist.
LOG_DIR="$REPORT_HOME/logs/devices/<device-id>"
tail -n 300 "$LOG_DIR/cli.log"
tail -n 300 "$LOG_DIR/xctest-holder.log"
```

Save a sanitized draft under `$REPORT_HOME/artifacts/` using a unique filename.
Set `REPORT` to that path for the commands below. Include available information:

- Summary
- Exact commands and full error output
- ios-use and macOS versions
- `ios-use status` and `ios-use config --list`
- Relevant redacted log excerpts
- Expected behavior
- Actual behavior
- Recovery already tried and its result; known/unknown reproduction conditions

Separate observations from hypotheses. Do not describe a suspected cause as
confirmed or a workaround as a verified fix. One observed failure is reportable;
maintainers can build a public minimal reproduction and compare environments.

Before creating the issue, redact sensitive values such as:

- full UDIDs: keep only prefix/suffix, for example `00008150-...401C`
- Apple IDs: use `<apple-id>`
- local user paths if needed: use `~`
- app-specific passwords, tokens, certificates, private keys: remove completely

## Create Issue

Prefer `gh`:

```bash
command -v gh
gh issue list --repo xhzq233/ios-use --search "<error keyword>" --state all
```

After searching for duplicates and reviewing the sanitized draft, submit it:

```bash
gh issue create \
  --repo xhzq233/ios-use \
  --title "<short failure title>" \
  --body-file "$REPORT"
```

For a matching issue with new evidence, comment instead:

```bash
gh issue comment <number> \
  --repo xhzq233/ios-use \
  --body-file "$REPORT"
```

Return the issue/comment URL and the relevant observation to the user, then
continue the original task where possible. Filing a report does not mean the
failure has been reproduced or fixed.

## Start Launch Failure Template

Use this title style for real-device driver launch failures:

```text
start: CoreDevice launchapplication 10002 should hint iPhone developer trust
```

Useful evidence when available (missing entries do not block submission):

- exact `ios-use start` error
- whether `ios-use ddi-mount --udid <udid>` was run and its result
- `ios-use status`
- `ios-use config --list`
- redacted excerpts from the target's `xctest-holder.log` and `cli.log`

For `CoreDevice.error code=10002` with `The application failed to launch`, mention whether the iPhone showed or required manual trust under Settings > General > VPN & Device Management.
