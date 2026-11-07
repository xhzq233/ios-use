#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_ROOT="${IOS_USE_HOME:-$ROOT/.ios-use}/self-runner"
SPEC="$ROOT/self-runner/project.yml"
EMBEDDED=0
DDI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --embedded-vpn) SPEC="$ROOT/self-runner/project-embedded.yml"; EMBEDDED=1; shift ;;
    --ddi)
      [[ $# -ge 2 ]] || { echo '--ddi requires an extracted Restore directory' >&2; exit 2; }
      DDI="$2"; shift 2 ;;
    *) echo 'Usage: scripts/build_self_runner.sh [--embedded-vpn] [--ddi <Restore directory>]' >&2; exit 2 ;;
  esac
done
if [[ -n "$DDI" ]]; then
  [[ -f "$DDI/BuildManifest.plist" ]] || { echo '--ddi must contain BuildManifest.plist (extract an outer iOS_DDI.dmg first)' >&2; exit 2; }
  DDI="$(cd "$DDI" && pwd)"
fi
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"
IOS_USE_REPOSITORY_ROOT="$ROOT" xcodegen generate --spec "$SPEC" --project "$ARTIFACT_ROOT"
xcodebuild -project "$ARTIFACT_ROOT/IOSUseSelfRunner.xcodeproj" \
  -scheme IOSUseSelfRunner -configuration Debug -sdk iphoneos \
  -derivedDataPath "$ARTIFACT_ROOT/build" -skipMacroValidation IOS_USE_REPOSITORY_ROOT="$ROOT" CODE_SIGNING_ALLOWED=NO build \
  > "$ARTIFACT_ROOT/build.log" 2>&1 || { tail -80 "$ARTIFACT_ROOT/build.log"; exit 1; }
STAGE="$(mktemp -d "$ARTIFACT_ROOT/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$ARTIFACT_ROOT/build/Build/Products/Debug-iphoneos/IOSUseSelfRunner.app" "$STAGE/Payload/"
# An incremental build may retain an extension copied by a previous embedded
# build. The external-VPN artifact must contain only the runner and framework.
if [[ "$EMBEDDED" == 0 ]]; then
  rm -rf "$STAGE/Payload/IOSUseSelfRunner.app/PlugIns"
fi
# Bundle only explicitly supplied resources; never copy signing/pairing state.
rm -rf "$STAGE/Payload/IOSUseSelfRunner.app/DDI"
if [[ -n "$DDI" ]]; then
  python3 "$ROOT/scripts/package_self_runner_ddi.py" "$DDI" "$STAGE/Payload/IOSUseSelfRunner.app/DDI"
fi
(cd "$STAGE" && /usr/bin/zip -qr "$STAGE/self-runner.ipa" Payload)
mv "$STAGE/self-runner.ipa" "$ARTIFACT_ROOT/self-runner.ipa"
printf 'Unsigned IPA: %s\n' "$ARTIFACT_ROOT/self-runner.ipa"
