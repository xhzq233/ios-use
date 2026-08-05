#!/bin/bash
set -euo pipefail

IOS_USE_FIXTURE_ROOT="$(cd "$(dirname "$0")" && pwd)"
IOS_USE_FIXTURE_BUILD="$IOS_USE_FIXTURE_ROOT/.build"
IOS_USE_FIXTURE_CONFIGURATION="${IOS_USE_FIXTURE_CONFIGURATION:-Release}"
IOS_USE_FIXTURE_SDK="${IOS_USE_FIXTURE_SDK:-iphoneos}"
IOS_USE_FIXTURE_DERIVED_DATA="$IOS_USE_FIXTURE_BUILD/DerivedData"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --configuration)
      IOS_USE_FIXTURE_CONFIGURATION="$2"
      shift 2
      ;;
    --sdk)
      IOS_USE_FIXTURE_SDK="$2"
      shift 2
      ;;
    --derived-data-path)
      IOS_USE_FIXTURE_DERIVED_DATA="$2"
      shift 2
      ;;
    *)
      echo "[playcover-fixture] ERROR: unknown argument: $1"
      exit 2
      ;;
  esac
done

case "$IOS_USE_FIXTURE_CONFIGURATION" in
  Debug|Release) ;;
  *)
    echo "[playcover-fixture] ERROR: configuration must be Debug or Release"
    exit 2
    ;;
esac

case "$IOS_USE_FIXTURE_SDK" in
  iphoneos|iphonesimulator) ;;
  *)
    echo "[playcover-fixture] ERROR: sdk must be iphoneos or iphonesimulator"
    exit 2
    ;;
esac

if [[ "$IOS_USE_FIXTURE_DERIVED_DATA" != /* ]]; then
  echo "[playcover-fixture] ERROR: derived data path must be absolute"
  exit 2
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[playcover-fixture] ERROR: xcodegen is required"
  exit 1
fi

mkdir -p "$IOS_USE_FIXTURE_BUILD"
xcodegen generate \
  --quiet \
  --spec "$IOS_USE_FIXTURE_ROOT/project.yml" \
  --project "$IOS_USE_FIXTURE_ROOT" \
  --project-root "$IOS_USE_FIXTURE_ROOT"

xcodebuild \
  -project "$IOS_USE_FIXTURE_ROOT/IOSUsePlayFixture.xcodeproj" \
  -scheme IOSUsePlayFixture \
  -configuration "$IOS_USE_FIXTURE_CONFIGURATION" \
  -sdk "$IOS_USE_FIXTURE_SDK" \
  -derivedDataPath "$IOS_USE_FIXTURE_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

IOS_USE_FIXTURE_APP="$IOS_USE_FIXTURE_DERIVED_DATA/Build/Products/${IOS_USE_FIXTURE_CONFIGURATION}-${IOS_USE_FIXTURE_SDK}/IOSUsePlayFixture.app"
if [ ! -d "$IOS_USE_FIXTURE_APP" ]; then
  echo "[playcover-fixture] ERROR: expected App not found: $IOS_USE_FIXTURE_APP"
  exit 1
fi

echo "[playcover-fixture] Built $IOS_USE_FIXTURE_APP"
