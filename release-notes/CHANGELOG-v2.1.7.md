# ios-use v2.1.7

- Add native App sandbox file operations (`ios-use file ls | pull | push | rm`) over `com.apple.mobile.house_arrest` + AFC for both macOS USB real iOS devices and macOS/Linux remote (`--connection`) real iOS devices.
- Support full container access (`VendContainer`, default) and `--documents` (`VendDocuments`), recursive directory push/pull, `--force` overwrite, `--json` structured output, and Seatbelt `PERM_DENIED` handling on real-device sandbox roots and `/SystemData`.
- Consolidate GitHub Actions CI into a unified change-aware `ci.yml` alongside `release.yml`, removing unused workflows and redundant cache invalidation.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

For each running Mac App, stop it and run
`ios-use start --mac --app <source.app>` to prepare it with the updated Runtime.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.7/scripts/install.sh | bash -s -- --version v2.1.7
```
