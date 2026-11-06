#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_ROOT="${IOS_USE_HOME:-$ROOT/.ios-use}/self-runner"
SPEC="$ROOT/self-runner/project.yml"
if [[ "${1:-}" == --embedded-vpn ]]; then
  SPEC="$ROOT/self-runner/project-embedded.yml"
elif [[ $# -gt 0 ]]; then
  echo 'Usage: scripts/build_self_runner.sh [--embedded-vpn]' >&2
  exit 2
fi
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"
xcodegen generate --spec "$SPEC" --project "$ARTIFACT_ROOT"
xcodebuild -project "$ARTIFACT_ROOT/IOSUseSelfRunner.xcodeproj" \
  -scheme IOSUseSelfRunner -configuration Debug -sdk iphoneos \
  -derivedDataPath "$ARTIFACT_ROOT/build" -skipMacroValidation IOS_USE_REPOSITORY_ROOT="$ROOT" CODE_SIGNING_ALLOWED=NO build \
  > "$ARTIFACT_ROOT/build.log" 2>&1 || { tail -80 "$ARTIFACT_ROOT/build.log"; exit 1; }
STAGE="$(mktemp -d "$ARTIFACT_ROOT/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$ARTIFACT_ROOT/build/Build/Products/Debug-iphoneos/IOSUseSelfRunner.app" "$STAGE/Payload/"
(cd "$STAGE" && /usr/bin/zip -qr "$STAGE/self-runner.ipa" Payload)
mv "$STAGE/self-runner.ipa" "$ARTIFACT_ROOT/self-runner.ipa"
printf 'Unsigned IPA: %s\n' "$ARTIFACT_ROOT/self-runner.ipa"
