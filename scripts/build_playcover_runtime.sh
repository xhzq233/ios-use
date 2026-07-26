#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_USE_RUNTIME_OUTPUT="$IOS_USE_REPO_ROOT/.ios-use/playcover/IOSUsePlayRuntime.framework"
IOS_USE_RUNTIME_REPLACE="false"
IOS_USE_RUNTIME_ANALYZE="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      if [ "$#" -lt 2 ]; then
        echo "[playcover-runtime] ERROR: --output requires a path"
        exit 64
      fi
      IOS_USE_RUNTIME_OUTPUT="$2"
      shift 2
      ;;
    --replace)
      IOS_USE_RUNTIME_REPLACE="true"
      shift
      ;;
    --analyze)
      IOS_USE_RUNTIME_ANALYZE="true"
      shift
      ;;
    *)
      echo "[playcover-runtime] ERROR: unknown option $1"
      exit 64
      ;;
  esac
done

if [ "$(basename "$IOS_USE_RUNTIME_OUTPUT")" != "IOSUsePlayRuntime.framework" ]; then
  echo "[playcover-runtime] ERROR: output must end in IOSUsePlayRuntime.framework"
  exit 64
fi

IOS_USE_RUNTIME_PARENT="$(cd "$(dirname "$IOS_USE_RUNTIME_OUTPUT")" 2>/dev/null && pwd || true)"
if [ -z "$IOS_USE_RUNTIME_PARENT" ]; then
  mkdir -p "$(dirname "$IOS_USE_RUNTIME_OUTPUT")"
  IOS_USE_RUNTIME_PARENT="$(cd "$(dirname "$IOS_USE_RUNTIME_OUTPUT")" && pwd)"
fi
IOS_USE_RUNTIME_OUTPUT="$IOS_USE_RUNTIME_PARENT/IOSUsePlayRuntime.framework"

if [ -e "$IOS_USE_RUNTIME_OUTPUT" ] && [ "$IOS_USE_RUNTIME_REPLACE" != "true" ]; then
  echo "[playcover-runtime] ERROR: output exists; pass --replace to replace this generated framework"
  exit 1
fi

IOS_USE_RUNTIME_TEMP="$(mktemp -d "$IOS_USE_RUNTIME_PARENT/.ios-use-play-runtime.XXXXXX")"
cleanup_runtime_build() {
  if [ -n "${IOS_USE_RUNTIME_TEMP:-}" ] &&
     [ -d "$IOS_USE_RUNTIME_TEMP" ] &&
     [ "$(dirname "$IOS_USE_RUNTIME_TEMP")" = "$IOS_USE_RUNTIME_PARENT" ]; then
    rm -rf "$IOS_USE_RUNTIME_TEMP"
  fi
}
trap cleanup_runtime_build EXIT

IOS_USE_RUNTIME_SOURCE_ROOT="$IOS_USE_REPO_ROOT/playcover-runtime"
IOS_USE_RUNTIME_PROJECT_DIR="$IOS_USE_RUNTIME_TEMP/project"
IOS_USE_RUNTIME_PROJECT_PATH="$IOS_USE_RUNTIME_PROJECT_DIR/IOSUsePlayRuntime.xcodeproj"
IOS_USE_RUNTIME_PROJECT_SOURCE_ROOT="source-root/playcover-runtime"
IOS_USE_RUNTIME_DERIVED_DATA="$IOS_USE_RUNTIME_TEMP/DerivedData"
IOS_USE_RUNTIME_PRODUCTS="$IOS_USE_RUNTIME_TEMP/products"
IOS_USE_RUNTIME_FRAMEWORK="$IOS_USE_RUNTIME_PRODUCTS/IOSUsePlayRuntime.framework"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[playcover-runtime] ERROR: xcodegen is required to build the mixed Catalyst Runtime"
  exit 69
fi

mkdir -p "$IOS_USE_RUNTIME_PRODUCTS" "$IOS_USE_RUNTIME_PROJECT_DIR"
ln -s "$IOS_USE_REPO_ROOT" "$IOS_USE_RUNTIME_PROJECT_DIR/source-root"
IOS_USE_RUNTIME_SOURCE_ROOT="$IOS_USE_RUNTIME_PROJECT_SOURCE_ROOT" xcodegen \
  --quiet \
  --spec "$IOS_USE_RUNTIME_SOURCE_ROOT/project.yml" \
  --project "$IOS_USE_RUNTIME_PROJECT_DIR" \
  --project-root "$IOS_USE_RUNTIME_PROJECT_DIR"

IOS_USE_RUNTIME_XCODE_ARGS=(
  -quiet
  -project "$IOS_USE_RUNTIME_PROJECT_PATH"
  -scheme IOSUsePlayRuntime
  -configuration Release
  -destination "generic/platform=macOS,variant=Mac Catalyst"
  -derivedDataPath "$IOS_USE_RUNTIME_DERIVED_DATA"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGNING_ALLOWED=NO
  CONFIGURATION_BUILD_DIR="$IOS_USE_RUNTIME_PRODUCTS"
  IOS_USE_RUNTIME_SOURCE_ROOT="$IOS_USE_RUNTIME_SOURCE_ROOT"
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)

echo "[playcover-runtime] Building one mixed Objective-C/Swift Catalyst framework..."
xcodebuild "${IOS_USE_RUNTIME_XCODE_ARGS[@]}" build
if [ "$IOS_USE_RUNTIME_ANALYZE" = "true" ]; then
  echo "[playcover-runtime] Running Clang static analyzer..."
  xcodebuild "${IOS_USE_RUNTIME_XCODE_ARGS[@]}" analyze
fi

if [ ! -x "$IOS_USE_RUNTIME_FRAMEWORK/IOSUsePlayRuntime" ]; then
  echo "[playcover-runtime] ERROR: mixed framework product was not produced"
  exit 1
fi

IOS_USE_RUNTIME_INFO_PLIST="$IOS_USE_RUNTIME_FRAMEWORK/Info.plist"
if [ ! -f "$IOS_USE_RUNTIME_INFO_PLIST" ]; then
  IOS_USE_RUNTIME_INFO_PLIST="$IOS_USE_RUNTIME_FRAMEWORK/Versions/A/Resources/Info.plist"
fi
if [ ! -f "$IOS_USE_RUNTIME_INFO_PLIST" ]; then
  echo "[playcover-runtime] ERROR: framework Info.plist was not produced"
  exit 1
fi
plutil -lint -- "$IOS_USE_RUNTIME_INFO_PLIST"
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  "$IOS_USE_RUNTIME_FRAMEWORK"
/usr/bin/codesign --verify --strict "$IOS_USE_RUNTIME_FRAMEWORK"

if [ -e "$IOS_USE_RUNTIME_OUTPUT" ]; then
  rm -rf "$IOS_USE_RUNTIME_OUTPUT"
fi
mv "$IOS_USE_RUNTIME_FRAMEWORK" "$IOS_USE_RUNTIME_OUTPUT"

echo "[playcover-runtime] Built $IOS_USE_RUNTIME_OUTPUT"
