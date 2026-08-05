#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRIDA_COMMIT="0afeb85fcdeae1d995a55bc07f0fe57b197aecae"
FRIDA_REPOSITORY="https://github.com/frida/frida-gum.git"
FRIDA_BUILD_VERSION="16.5.6"
SOURCE_ROOT="${IOS_USE_FRIDA_SOURCE_ROOT:-}"
BUILD_ROOT="${IOS_USE_FRIDA_GUM_BUILD_ROOT:-}"
REPLACE=false

usage() {
  cat <<'EOF'
Usage: scripts/build_playcover_frida_gum_catalyst.sh
  [--source-root <pinned frida-gum checkout>]
  [--build-root <build directory>]
  [--replace]

Build the pinned official Frida GumJS QuickJS devkit for arm64 Mac Catalyst.
The wrapper Engine build consumes the resulting
<build-root>/bindings/gumjs/devkit directory.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root)
      [ "$#" -ge 2 ] || { echo "--source-root requires a path" >&2; exit 64; }
      SOURCE_ROOT="$2"; shift 2 ;;
    --build-root)
      [ "$#" -ge 2 ] || { echo "--build-root requires a path" >&2; exit 64; }
      BUILD_ROOT="$2"; shift 2 ;;
    --replace) REPLACE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ -z "$SOURCE_ROOT" ]; then
  cache_root="${IOS_USE_FRIDA_SOURCE_CACHE:-$HOME/Library/Caches/dev.ios-use/mac/frida-engine/source}"
  SOURCE_ROOT="$cache_root/$FRIDA_COMMIT"
  mkdir -p "$(dirname "$SOURCE_ROOT")"
  if [ ! -d "$SOURCE_ROOT/.git" ]; then
    git clone --filter=blob:none "$FRIDA_REPOSITORY" "$SOURCE_ROOT"
  fi
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
if [ -e "$SOURCE_ROOT/.git" ]; then
  if [ -n "$(git -C "$SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" ]; then
    echo "Frida source checkout is dirty; refusing to change it before pinning $FRIDA_COMMIT" >&2
    exit 65
  fi
  actual_commit="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
  if [ "$actual_commit" != "$FRIDA_COMMIT" ]; then
    git -C "$SOURCE_ROOT" fetch --no-tags --depth=1 origin "$FRIDA_COMMIT"
    git -C "$SOURCE_ROOT" checkout --detach "$FRIDA_COMMIT"
    actual_commit="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
  fi
  if [ "$actual_commit" != "$FRIDA_COMMIT" ]; then
    echo "Frida source is $actual_commit, expected pinned $FRIDA_COMMIT" >&2
    exit 65
  fi
  git -C "$SOURCE_ROOT" submodule update --init --recursive
else
  python3 "$ROOT_DIR/scripts/frida_distribution.py" validate-source \
    --repository-root "$ROOT_DIR" \
    --source-root "$SOURCE_ROOT"
fi

if [ -z "$BUILD_ROOT" ]; then
  cache_root="${IOS_USE_FRIDA_BUILD_CACHE:-$HOME/Library/Caches/dev.ios-use/mac/frida-engine/build}"
  BUILD_ROOT="$cache_root/$FRIDA_COMMIT/catalyst-arm64"
fi
BUILD_ROOT="$(mkdir -p "$(dirname "$BUILD_ROOT")" && cd "$(dirname "$BUILD_ROOT")" && pwd)/$(basename "$BUILD_ROOT")"
if [ -e "$BUILD_ROOT" ] && [ "$REPLACE" = true ]; then
  case "$BUILD_ROOT" in
    /|"$HOME"|"$ROOT_DIR")
      echo "refusing to replace broad build root: $BUILD_ROOT" >&2
      exit 64
      ;;
  esac
  rm -rf -- "$BUILD_ROOT"
fi
mkdir -p "$BUILD_ROOT"

PYTHON="${PYTHON:-$(command -v python3)}"
NINJA="${NINJA:-$(command -v ninja)}"
[ -n "$PYTHON" ] || { echo "python3 is required" >&2; exit 69; }
[ -n "$NINJA" ] || { echo "ninja is required" >&2; exit 69; }
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-ios17.0-macabi"
PKG_CONFIG_WRAPPER="$ROOT_DIR/scripts/frida_pkg_config.py"

if [ -n "${MESON:-}" ]; then
  MESON_COMMAND=("$MESON")
elif command -v meson >/dev/null 2>&1; then
  MESON_COMMAND=("$(command -v meson)")
elif "$PYTHON" -m mesonbuild.mesonmain --version >/dev/null 2>&1; then
  MESON_COMMAND=("$PYTHON" -m mesonbuild.mesonmain)
else
  echo "Meson 1.11.x is required; install it or set MESON/PYTHON" >&2
  exit 69
fi

# Frida keeps QuickJS as a pinned Meson wrap rather than a Git submodule.
# A clean source checkout therefore has no source directory until the wrap is
# materialized explicitly; warm developer caches used to hide this requirement.
QUICKJS_SOURCE="$SOURCE_ROOT/subprojects/quickjs"
if [ ! -f "$QUICKJS_SOURCE/meson.build" ]; then
  "${MESON_COMMAND[@]}" subprojects download \
    --sourcedir "$SOURCE_ROOT" \
    quickjs
fi
[ -f "$QUICKJS_SOURCE/meson.build" ] || {
  echo "pinned QuickJS Meson wrap was not materialized" >&2
  exit 65
}

NATIVE_BUILD="$BUILD_ROOT/quickjs-native"
CROSS_QUICKJS_BUILD="$BUILD_ROOT/quickjs-catalyst"
GUM_BUILD="$BUILD_ROOT/gum-catalyst"
CONFIG_ROOT="$BUILD_ROOT/config"
mkdir -p "$CONFIG_ROOT"

TARGET_PKG_CONFIG_PATH="$GUM_BUILD/meson-uninstalled:$CROSS_QUICKJS_BUILD/meson-uninstalled"
NATIVE_PKG_CONFIG_PATH="$NATIVE_BUILD/meson-uninstalled"
TARGET_PKG_CONFIG="$CONFIG_ROOT/pkg-config-target"
NATIVE_PKG_CONFIG="$CONFIG_ROOT/pkg-config-native"
write_target_pkg_config() {
  local package_path="$1"
  cat > "$TARGET_PKG_CONFIG" <<EOF
#!/bin/sh
exec env IOS_USE_FRIDA_PKG_CONFIG_PATH="$package_path" \
  "$PYTHON" "$PKG_CONFIG_WRAPPER" "\$@"
EOF
  chmod 755 "$TARGET_PKG_CONFIG"
}
write_target_pkg_config "$CROSS_QUICKJS_BUILD/meson-uninstalled"
cat > "$NATIVE_PKG_CONFIG" <<EOF
#!/bin/sh
exec env IOS_USE_FRIDA_PKG_CONFIG_PATH="$NATIVE_PKG_CONFIG_PATH" \
  "$PYTHON" "$PKG_CONFIG_WRAPPER" "\$@"
EOF
chmod 755 "$NATIVE_PKG_CONFIG"

"$PYTHON" - "$CONFIG_ROOT" "$SDK_PATH" "$TARGET" \
    "$TARGET_PKG_CONFIG" "$NATIVE_PKG_CONFIG" \
    "$SOURCE_ROOT" "$GUM_BUILD" <<'PY'
import os
import pathlib
import sys

root, sdk, target, target_pkg, native_pkg, source, gum_build = sys.argv[1:]
root = pathlib.Path(root)
source_argument = os.path.relpath(
    os.path.realpath(source),
    os.path.realpath(gum_build),
)
reproducible_args = [
    f'-ffile-prefix-map={source_argument}=frida-gum',
]
cross = f'''[binaries]
c = ['clang', '-target', '{target}', '-isysroot', '{sdk}']
cpp = ['clang++', '-target', '{target}', '-isysroot', '{sdk}']
objc = ['clang', '-target', '{target}', '-isysroot', '{sdk}']
objcpp = ['clang++', '-target', '{target}', '-isysroot', '{sdk}']
ar = 'ar'
ranlib = 'ranlib'
strip = 'strip'
pkg-config = '{target_pkg}'

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
c_args = {reproducible_args!r}
cpp_args = {reproducible_args!r}
objc_args = {reproducible_args!r}
objcpp_args = {reproducible_args!r}
'''
native_file = f'''[binaries]
pkg-config = '{native_pkg}'

[built-in options]
c_args = {reproducible_args!r}
cpp_args = {reproducible_args!r}
objc_args = {reproducible_args!r}
objcpp_args = {reproducible_args!r}
'''
cross_native = f'''[binaries]
pkg-config = '{native_pkg}'

[built-in options]
c_args = {reproducible_args!r}
cpp_args = {reproducible_args!r}
objc_args = {reproducible_args!r}
objcpp_args = {reproducible_args!r}
'''
(root / 'catalyst.ini').write_text(cross)
(root / 'native.ini').write_text(native_file)
(root / 'gum-native.ini').write_text(cross_native)
PY

if [ ! -f "$NATIVE_BUILD/build.ninja" ]; then
  "${MESON_COMMAND[@]}" setup "$NATIVE_BUILD" "$QUICKJS_SOURCE" \
    --native-file "$CONFIG_ROOT/native.ini" \
    -Dbuildtype=release -Dlibc=false -Dbignum=true \
    -Datomics=disabled -Dstack_check=disabled -Ddefault_library=static
fi
"$NINJA" -C "$NATIVE_BUILD"

if [ ! -f "$CROSS_QUICKJS_BUILD/build.ninja" ]; then
  "${MESON_COMMAND[@]}" setup "$CROSS_QUICKJS_BUILD" "$QUICKJS_SOURCE" \
    --cross-file "$CONFIG_ROOT/catalyst.ini" \
    -Dbuildtype=release -Dlibc=false -Dbignum=true \
    -Datomics=disabled -Dstack_check=disabled -Ddefault_library=static
fi
"$NINJA" -C "$CROSS_QUICKJS_BUILD"

if [ ! -f "$GUM_BUILD/build.ninja" ]; then
  "${MESON_COMMAND[@]}" setup "$GUM_BUILD" "$SOURCE_ROOT" \
    --cross-file "$CONFIG_ROOT/catalyst.ini" \
    --native-file "$CONFIG_ROOT/gum-native.ini" \
    -Dbuildtype=release -Ddefault_library=static \
    -Dfrida_version="$FRIDA_BUILD_VERSION" \
    -Dgumjs=enabled -Dquickjs=enabled -Dv8=disabled \
    -Dtests=disabled -Dgraft_tool=disabled -Dgumpp=disabled \
    -Ddevkits=gumjs
fi
# The pinned libffi Meson probe enables DWARF CFI for non-ptrauth arm64 even
# though Apple's Catalyst assembler rejects two of libffi's generated CFI
# expressions.  Disable only that generated unwind metadata; the pinned
# source and executable libffi code remain unchanged.  Apply this after every
# setup so an empty checkout and a resumed build have the same result.
LIBFFI_CONFIG="$GUM_BUILD/subprojects/libffi/fficonfig.h"
"$PYTHON" - "$LIBFFI_CONFIG" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
enabled = b"#define HAVE_AS_CFI_PSEUDO_OP 1\n"
disabled = b"/* #undef HAVE_AS_CFI_PSEUDO_OP */\n"
data = path.read_bytes()
if data.count(enabled) == 1 and data.count(disabled) == 0:
    path.write_bytes(data.replace(enabled, disabled))
elif data.count(enabled) != 0 or data.count(disabled) != 1:
    raise SystemExit(
        "unexpected pinned libffi CFI configuration: " + str(path)
    )
PY
# The generated Gum .pc files must not be visible while Meson configures the
# project: doing so makes GLib look like an already-installed dependency and
# prevents Frida's pinned fallback subproject from generating its headers.
# They are needed by the post-build devkit/pkg-config steps, so expose them
# only after setup has completed.
write_target_pkg_config "$TARGET_PKG_CONFIG_PATH"
"$NINJA" -C "$GUM_BUILD"

DEVKIT="$GUM_BUILD/bindings/gumjs/devkit"
[ -f "$DEVKIT/frida-gumjs.h" ] || { echo "GumJS devkit header was not generated" >&2; exit 65; }
[ -f "$DEVKIT/libfrida-gumjs.a" ] || { echo "GumJS devkit archive was not generated" >&2; exit 65; }
echo "Built pinned Frida GumJS Catalyst devkit at $DEVKIT"
