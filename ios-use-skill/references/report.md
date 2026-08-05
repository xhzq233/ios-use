# ios-use Report / GitHub Issue

Use this reference when reporting an ios-use failure upstream.

## Rules

- Do not attach secrets: Apple ID, app-specific password, certificate/private-key material, full UDID, private app logs, tokens, or local account paths that identify people.
- Keep enough evidence to reproduce the failure: exact command, full error text, ios-use version, device/iOS version, config status, and relevant log tails.
- Prefer log tails over full logs. Start with 200-400 lines from the relevant files.
- Before drafting a new issue, search existing GitHub Issues for similar symptoms and link useful matches in the final report.
- Do not submit an issue until the user clearly asks to submit it; a short instruction such as "提交吧" is sufficient. Preparing a local draft is fine before that.
- Use the `gh` CLI first for GitHub Issues operations. If `gh` is missing, ask before installing it or use another available GitHub tool.
- If the issue is about `start`, include `~/.ios-use/logs/xctest-holder.log` and `~/.ios-use/logs/cli.log`.
- If the issue is about driver commands after `start`, include `~/.ios-use/logs/driver.log` if present.
- If the issue is about proxy, include `ios-use proxy doctor` and proxy state, but do not include captured request bodies unless explicitly safe.

## Collect

Collect the current environment and only the relevant log tails:

```bash
ios-use --version
sw_vers
ios-use status
ios-use config --list
tail -n 300 ~/.ios-use/logs/xctest-holder.log
tail -n 300 ~/.ios-use/logs/cli.log
tail -n 300 ~/.ios-use/logs/driver.log
```

Create `/tmp/ios-use-report.md` with these sections:

- Summary
- Exact commands and full error output
- ios-use and macOS versions
- `ios-use status` and `ios-use config --list`
- Relevant redacted log tails
- Expected behavior
- Actual behavior

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

After reviewing the draft and receiving a clear submit instruction from the user:

```bash
gh issue create \
  --repo xhzq233/ios-use \
  --title "<short failure title>" \
  --body-file "$REPORT"
```

If labels are useful and available:

```bash
gh issue create \
  --repo xhzq233/ios-use \
  --title "<short failure title>" \
  --label bug \
  --body-file "$REPORT"
```

## Start Launch Failure Template

Use this title style for real-device driver launch failures:

```text
start: CoreDevice launchapplication 10002 should hint iPhone developer trust
```

Minimum body evidence:

- exact `ios-use start` error
- whether `ios-use ddi-mount --udid <udid>` was run and its result
- `ios-use status`
- `ios-use config --list`
- tail of `~/.ios-use/logs/xctest-holder.log`
- tail of `~/.ios-use/logs/cli.log`

For `CoreDevice.error code=10002` with `The application failed to launch`, mention whether the iPhone showed or required manual trust under Settings > General > VPN & Device Management.
