#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${IOS_USE_PLAYCOVER_UPSTREAM_CACHE:-${TMPDIR:-/tmp}/ios-use-playcover-upstream-audit}"
AUDIT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-playcover-audit.XXXXXX")"
METADATA_ONLY=0

cleanup() {
  rm -rf "$AUDIT_TEMP"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: scripts/audit_playcover_upstreams.sh [--cache-dir <directory>] [--metadata-only]

Checks the pinned upstream remote, commit, license, and byte diff for every
vendored PlayCover, PlayTools, and inject source file, plus the exact Yams
SwiftPM pin and license. Expected imported-file manifests are checked in both
the script and provenance so a missing vendored source cannot disappear from
the audit silently. A changed imported file must be named in the provenance
file's recorded-local-patches block; both an unrecorded patch and a stale patch
record fail the audit. The cache is an external checkout used only as audit
evidence; vendored directories are not assumed to be Git repositories.

--metadata-only validates the script/provenance pins, expected vendored file
sets, and SwiftPM resolution without cloning the upstream checkouts.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --metadata-only)
      METADATA_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

canonical_remote() {
  local remote="$1"
  printf '%s\n' "${remote%.git}" | sed 's#^git@github.com:#https://github.com/#'
}

require_exact_text() {
  local file="$1"
  local text="$2"
  local description="$3"
  local count
  count="$(grep -F -c -- "$text" "$file" || true)"
  if [[ "$count" != "1" ]]; then
    echo "[upstream-audit] ERROR: $description must appear exactly once in $file." >&2
    exit 1
  fi
}

require_ordered_text() {
  local file="$1"
  local description="$2"
  shift 2
  local previous=0
  local text line
  for text in "$@"; do
    require_exact_text "$file" "$text" "$description symbol '$text'"
    line="$(grep -F -n -- "$text" "$file" | cut -d: -f1)"
    if (( line <= previous )); then
      echo "[upstream-audit] ERROR: $description is not in pinned source order in $file." >&2
      exit 1
    fi
    previous="$line"
  done
  echo "[upstream-audit] $description: exact ordered symbols"
}

verify_provenance_metadata() {
  local name="$1"
  local provenance="$2"
  local remote="$3"
  local commit="$4"
  local license="$5"
  require_exact_text "$provenance" "- Upstream: $remote" "$name upstream remote"
  require_exact_text "$provenance" "- Pinned commit: \`$commit\`" "$name pinned commit"
  require_exact_text "$provenance" "- License: $license; see \`LICENSE\`" "$name license declaration"
  echo "[upstream-audit] $name provenance pin: exact script match"
}

verify_resolved_pin() {
  local resolved="$1"
  local identity="$2"
  local remote="$3"
  local commit="$4"
  local version="$5"
  local pin_block="$AUDIT_TEMP/resolved.$(basename "$(dirname "$resolved")").$identity"

  awk -v identity="\"identity\" : \"$identity\"" '
    index($0, identity) {
      if (found) {
        duplicate = 1
      }
      found = 1
      capture = 1
    }
    capture { print }
    capture && /"version"[[:space:]]*:/ { capture = 0 }
    END {
      if (!found || duplicate) {
        exit 1
      }
    }
  ' "$resolved" > "$pin_block" || {
    echo "[upstream-audit] ERROR: $resolved must resolve exactly one $identity pin." >&2
    exit 1
  }

  require_exact_text "$pin_block" "\"location\" : \"$remote\"" "$resolved $identity remote"
  require_exact_text "$pin_block" "\"revision\" : \"$commit\"" "$resolved $identity revision"
  require_exact_text "$pin_block" "\"version\" : \"$version\"" "$resolved $identity version"
  echo "[upstream-audit] $resolved $identity resolution: exact pin"
}

extract_provenance_list() {
  local provenance="$1"
  local marker="$2"
  local output="$3"
  if ! grep -q "<!-- $marker:start -->" "$provenance" ||
     ! grep -q "<!-- $marker:end -->" "$provenance"; then
    echo "[upstream-audit] ERROR: $provenance lacks the $marker block." >&2
    exit 1
  fi
  awk -v start="<!-- $marker:start -->" -v end="<!-- $marker:end -->" '
    index($0, start) { capture = 1; next }
    index($0, end) { capture = 0; next }
    capture && /^- `[^`]+`$/ {
      value = $0
      sub(/^- `/, "", value)
      sub(/`$/, "", value)
      print value
    }
  ' "$provenance" > "$output"
}

verify_expected_vendored_files() {
  local name="$1"
  local provenance="$2"
  local vendored="$3"
  local exclude_prefix="$4"
  shift 4
  local expected="$AUDIT_TEMP/$name.expected"
  local recorded="$AUDIT_TEMP/$name.recorded-files"
  local actual="$AUDIT_TEMP/$name.actual-files"
  local relative

  printf '%s\n' "$@" | LC_ALL=C sort -u > "$expected"
  if [[ "$(wc -l < "$expected" | tr -d ' ')" != "$#" ]]; then
    echo "[upstream-audit] ERROR: $name script expected-file manifest contains duplicates." >&2
    exit 1
  fi
  while IFS= read -r relative; do
    case "$relative" in
      ""|/*|..|../*|*/..|*/../*)
        echo "[upstream-audit] ERROR: unsafe $name expected path: $relative" >&2
        exit 1
        ;;
    esac
  done < "$expected"

  extract_provenance_list "$provenance" audit-vendored-files "$recorded"
  LC_ALL=C sort -u "$recorded" -o "$recorded"
  if ! cmp -s "$expected" "$recorded"; then
    echo "[upstream-audit] ERROR: $name script and provenance expected-file manifests differ." >&2
    diff -u --label "$name script expected" --label "$name provenance expected" \
      "$expected" "$recorded" >&2 || true
    exit 1
  fi

  (
    cd "$vendored"
    find . -type f \( -name '*.swift' -o -name '*.m' -o -name '*.h' -o -name '*.yaml' \) \
      -print
  ) |
    sed 's#^\./##' |
    while IFS= read -r relative; do
      if [[ -n "$exclude_prefix" && "$relative" == "$exclude_prefix"* ]]; then
        continue
      fi
      printf '%s\n' "$relative"
    done |
    LC_ALL=C sort -u > "$actual"

  if ! cmp -s "$expected" "$actual"; then
    echo "[upstream-audit] ERROR: $name vendored source set is incomplete or unexpected." >&2
    diff -u --label "$name expected vendored files" --label "$name actual vendored files" \
      "$expected" "$actual" >&2 || true
    exit 1
  fi
  printf '[upstream-audit] %s vendored file set: %s file(s), exact script/provenance/tree match\n' \
    "$name" "$#"
}

checkout_pinned() {
  local name="$1"
  local remote="$2"
  local commit="$3"
  local checkout="$CACHE_DIR/$name"
  mkdir -p "$CACHE_DIR"
  if [[ ! -d "$checkout/.git" ]]; then
    echo "[upstream-audit] cloning $name" >&2
    git clone --quiet --filter=blob:none "$remote" "$checkout"
  fi
  if [[ -n "$(git -C "$checkout" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "[upstream-audit] ERROR: $name audit cache checkout is dirty; refusing untrusted upstream evidence at $checkout" >&2
    exit 1
  fi
  local actual_remote
  actual_remote="$(canonical_remote "$(git -C "$checkout" remote get-url origin)")"
  if [[ "$actual_remote" != "$(canonical_remote "$remote")" ]]; then
    echo "[upstream-audit] ERROR: $name origin is $actual_remote, expected $(canonical_remote "$remote")" >&2
    exit 1
  fi
  if ! git -C "$checkout" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$checkout" fetch --quiet origin "$commit"
  fi
  git -C "$checkout" checkout --quiet --detach "$commit"
  if [[ "$(git -C "$checkout" rev-parse HEAD)" != "$commit" ]]; then
    echo "[upstream-audit] ERROR: $name did not resolve to $commit" >&2
    exit 1
  fi
  printf '%s\n' "$checkout"
}

verify_license() {
  local name="$1"
  local upstream="$2"
  local vendored="$3"
  if ! cmp -s "$upstream/LICENSE" "$vendored/LICENSE"; then
    echo "[upstream-audit] ERROR: $name LICENSE differs from its pinned upstream." >&2
    exit 1
  fi
  echo "[upstream-audit] $name license: exact pinned copy"
}

audit_file() {
  local name="$1"
  local upstream="$2"
  local upstream_relative="$3"
  local vendored="$4"
  local vendored_relative="$5"
  local actual_patches="$6"
  local upstream_file="$upstream/$upstream_relative"
  local vendored_file="$vendored/$vendored_relative"
  if [[ ! -f "$upstream_file" || ! -f "$vendored_file" ]]; then
    echo "[upstream-audit] ERROR: missing $name audit file: $upstream_relative -> $vendored_relative" >&2
    exit 1
  fi
  local upstream_hash vendored_hash
  upstream_hash="$(shasum -a 256 "$upstream_file" | awk '{print $1}')"
  vendored_hash="$(shasum -a 256 "$vendored_file" | awk '{print $1}')"
  printf '[upstream-audit] %s %s upstream=%s vendored=%s\n' \
    "$name" "$upstream_relative" "$upstream_hash" "$vendored_hash"
  if [[ "$upstream_hash" != "$vendored_hash" ]]; then
    printf '%s\n' "$upstream_relative" >> "$actual_patches"
    echo "[upstream-audit] local patch diff: $name/$upstream_relative"
    diff -u --label "upstream/$name/$upstream_relative" \
      --label "vendored/$vendored_relative" \
      "$upstream_file" "$vendored_file" || true
  fi
}

audit_expected_files() {
  local name="$1"
  local upstream="$2"
  local vendored="$3"
  local upstream_base="$4"
  local vendored_base="$5"
  local actual_patches="$6"
  shift 6
  local relative
  for relative in "$@"; do
    local upstream_relative vendored_relative
    if [[ "$upstream_base" == "." ]]; then
      upstream_relative="$relative"
    else
      upstream_relative="${upstream_base%/}/$relative"
    fi
    if [[ "$vendored_base" == "." ]]; then
      vendored_relative="$relative"
    else
      vendored_relative="${vendored_base%/}/$relative"
    fi
    audit_file "$name" "$upstream" "$upstream_relative" \
      "$vendored" "$vendored_relative" "$actual_patches"
  done
}

verify_recorded_patches() {
  local name="$1"
  local provenance="$2"
  local actual_patches="$3"
  local recorded_patches="$AUDIT_TEMP/$name.recorded"
  local actual_sorted="$AUDIT_TEMP/$name.actual.sorted"
  local recorded_sorted="$AUDIT_TEMP/$name.recorded.sorted"

  extract_provenance_list "$provenance" audit-local-patches "$recorded_patches"

  LC_ALL=C sort -u "$actual_patches" > "$actual_sorted"
  LC_ALL=C sort -u "$recorded_patches" > "$recorded_sorted"
  if ! cmp -s "$actual_sorted" "$recorded_sorted"; then
    echo "[upstream-audit] ERROR: $name local source patches do not match PROVENANCE.md." >&2
    diff -u \
      --label "$name recorded patches" \
      --label "$name actual patches" \
      "$recorded_sorted" "$actual_sorted" >&2 || true
    exit 1
  fi
  printf '[upstream-audit] %s recorded patch set: %s file(s), exact match\n' \
    "$name" "$(wc -l < "$actual_sorted" | tr -d ' ')"
}

PLAYCOVER_REMOTE="https://github.com/PlayCover/PlayCover.git"
PLAYCOVER_COMMIT="7190cc9ce57c8dee0e222918468f2579acc95e1b"
PLAYTOOLS_REMOTE="https://github.com/PlayCover/PlayTools.git"
PLAYTOOLS_COMMIT="d688f695e83bf080be9ad4b7346e914c7c343d96"
INJECT_REMOTE="https://github.com/paradiseduo/inject.git"
INJECT_COMMIT="e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb"
YAMS_REMOTE="https://github.com/jpsim/Yams.git"
YAMS_COMMIT="3036ba9d69cf1fd04d433527bc339dc0dc75433d"
YAMS_VERSION="5.1.3"

PLAYCOVER_IMPORTED_FILES=(
  "AppInstaller/Installer.swift"
  "Model/AppInfo.swift"
  "Model/BaseApp.swift"
  "Model/PlayApp.swift"
  "Model/PlayRules.swift"
  "PlayCoverError.swift"
  "Rules/default.yaml"
  "Utils/Entitlements.swift"
  "Utils/Extensions/DataExtensions.swift"
  "Utils/Extensions/FileExtensions.swift"
  "Utils/Extensions/URLExtensions.swift"
  "Utils/KeyCover.swift"
  "Utils/Macho.swift"
  "Utils/PlayTools.swift"
  "Utils/Shell.swift"
  "Utils/SystemConfig.swift"
)
PLAYTOOLS_IMPORTED_FILES=(
  "AKPlugin.swift"
  "PlayTools/Controls/Backend/Toucher.swift"
  "PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.h"
  "PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.m"
  "PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.h"
  "PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m"
  "PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.h"
  "PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m"
  "PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.h"
  "PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m"
  "PlayTools/Controls/PTFakeTouch/UIApplication+Private.h"
  "PlayTools/Controls/PTFakeTouch/UIEvent+Private.h"
  "PlayTools/Controls/PTFakeTouch/UITouch+Private.h"
  "PlayTools/MysticRunes/PlayedApple.swift"
  "PlayTools/MysticRunes/PlayedAppleDB.swift"
  "PlayTools/MysticRunes/PlayedAppleDBConstants.swift"
  "PlayTools/PlayLoader.h"
  "PlayTools/PlayLoader.m"
  "PlayTools/PlayScreen.swift"
  "Plugin.swift"
)
INJECT_IMPORTED_FILES=(
  "BitType.swift"
  "Command.swift"
  "Extension.swift"
  "Inject.swift"
  "Shell.swift"
)

verify_provenance_metadata PlayCover \
  "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" \
  "$PLAYCOVER_REMOTE" "$PLAYCOVER_COMMIT" "GPL-3.0"
verify_provenance_metadata PlayTools \
  "$ROOT_DIR/playcover-runtime/PlayTools/PROVENANCE.md" \
  "$PLAYTOOLS_REMOTE" "$PLAYTOOLS_COMMIT" "AGPL-3.0"
verify_provenance_metadata inject \
  "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" \
  "$INJECT_REMOTE" "$INJECT_COMMIT" "GPL-3.0"
verify_provenance_metadata Yams \
  "$ROOT_DIR/ThirdParty/Yams/PROVENANCE.md" \
  "$YAMS_REMOTE" "$YAMS_COMMIT" "MIT"
require_exact_text "$ROOT_DIR/ThirdParty/Yams/PROVENANCE.md" \
  "- Pinned version: \`$YAMS_VERSION\`" \
  "Yams pinned version"
require_exact_text "$ROOT_DIR/ThirdParty/LICENSES.md" \
  "| PlayCover | \`$PLAYCOVER_COMMIT\` | GPL-3.0 — \`ThirdParty/PlayCover/LICENSE\` | \`ThirdParty/PlayCover/PROVENANCE.md\` |" \
  "PlayCover third-party license manifest entry"
require_exact_text "$ROOT_DIR/ThirdParty/LICENSES.md" \
  "| PlayTools | \`$PLAYTOOLS_COMMIT\` | AGPL-3.0 — \`playcover-runtime/PlayTools/LICENSE\` | \`playcover-runtime/PlayTools/PROVENANCE.md\` |" \
  "PlayTools third-party license manifest entry"
require_exact_text "$ROOT_DIR/ThirdParty/LICENSES.md" \
  "| inject | \`$INJECT_COMMIT\` | GPL-3.0 — \`ThirdParty/inject/LICENSE\` | \`ThirdParty/inject/PROVENANCE.md\` |" \
  "inject third-party license manifest entry"
require_exact_text "$ROOT_DIR/ThirdParty/LICENSES.md" \
  "| Yams | \`$YAMS_COMMIT\` | MIT — \`ThirdParty/Yams/LICENSE\` | \`ThirdParty/Yams/PROVENANCE.md\` |" \
  "Yams third-party license manifest entry"

verify_expected_vendored_files PlayCover \
  "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" \
  "$ROOT_DIR/ThirdParty/PlayCover/PlayCover" "Headless/" \
  "${PLAYCOVER_IMPORTED_FILES[@]}"
verify_expected_vendored_files PlayTools \
  "$ROOT_DIR/playcover-runtime/PlayTools/PROVENANCE.md" \
  "$ROOT_DIR/playcover-runtime/PlayTools" "" \
  "${PLAYTOOLS_IMPORTED_FILES[@]}"
verify_expected_vendored_files inject \
  "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" \
  "$ROOT_DIR/ThirdParty/inject/Injection/Injection" "" \
  "${INJECT_IMPORTED_FILES[@]}"

for playcover_source in "${PLAYCOVER_IMPORTED_FILES[@]}"; do
  if [[ "$playcover_source" == "Rules/default.yaml" ]]; then
    require_exact_text "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
      ".copy(\"$playcover_source\")" \
      "PlayCover Package.swift resource membership for $playcover_source"
  elif [[ "$playcover_source" == "Model/PlayApp.swift" ]]; then
    require_exact_text "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
      "exclude: [\"$playcover_source\"]," \
      "PlayCover Package.swift explicit GUI exclusion for $playcover_source"
  else
    require_exact_text "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
      "\"$playcover_source\"" \
      "PlayCover Package.swift source membership for $playcover_source"
  fi
done
require_ordered_text \
  "$ROOT_DIR/ThirdParty/PlayCover/PlayCover/Model/PlayApp.swift" \
  "PlayApp.sign entitlement/root-signing authority" \
  "func sign() {" \
  "let conf = try Entitlements.composeEntitlements(self)" \
  "try conf.store(tmpEnts)" \
  "try Shell.signAppWith(executable, entitlements: tmpEnts)"
require_exact_text "$ROOT_DIR/ThirdParty/inject/Package.swift" \
  'path: "Injection/Injection"' \
  "inject Package.swift vendored source membership"
require_exact_text "$ROOT_DIR/playcover-runtime/project.yml" \
  '- path: "${IOS_USE_RUNTIME_SOURCE_ROOT}"' \
  "PlayTools recursive Runtime project membership"
require_exact_text "$ROOT_DIR/playcover-runtime/project.yml" \
  '- path: "${IOS_USE_RUNTIME_SOURCE_ROOT}/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.h"' \
  "PlayTools public fake-touch header membership"

require_exact_text "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
  "url: \"$YAMS_REMOTE\"" "PlayCover Package.swift Yams remote"
require_exact_text "$ROOT_DIR/ThirdParty/PlayCover/Package.swift" \
  "exact: \"$YAMS_VERSION\"" "PlayCover Package.swift Yams exact version"
verify_resolved_pin "$ROOT_DIR/ThirdParty/PlayCover/Package.resolved" \
  yams "$YAMS_REMOTE" "$YAMS_COMMIT" "$YAMS_VERSION"
verify_resolved_pin "$ROOT_DIR/swift-cli/Package.resolved" \
  yams "$YAMS_REMOTE" "$YAMS_COMMIT" "$YAMS_VERSION"

if [[ "$METADATA_ONLY" -eq 1 ]]; then
  echo "[upstream-audit] PASS: provenance pins, SwiftPM resolution, and expected vendored files audited"
  exit 0
fi

PLAYCOVER_UPSTREAM="$(checkout_pinned PlayCover "$PLAYCOVER_REMOTE" "$PLAYCOVER_COMMIT")"
PLAYTOOLS_UPSTREAM="$(checkout_pinned PlayTools "$PLAYTOOLS_REMOTE" "$PLAYTOOLS_COMMIT")"
INJECT_UPSTREAM="$(checkout_pinned inject "$INJECT_REMOTE" "$INJECT_COMMIT")"
YAMS_UPSTREAM="$(checkout_pinned Yams "$YAMS_REMOTE" "$YAMS_COMMIT")"
YAMS_TAG_COMMIT="$(git -C "$YAMS_UPSTREAM" rev-parse "$YAMS_VERSION^{commit}")"
if [[ "$YAMS_TAG_COMMIT" != "$YAMS_COMMIT" ]]; then
  echo "[upstream-audit] ERROR: Yams tag $YAMS_VERSION resolves to $YAMS_TAG_COMMIT, expected $YAMS_COMMIT" >&2
  exit 1
fi
echo "[upstream-audit] Yams tag $YAMS_VERSION: exact pinned commit"

verify_license PlayCover "$PLAYCOVER_UPSTREAM" "$ROOT_DIR/ThirdParty/PlayCover"
verify_license PlayTools "$PLAYTOOLS_UPSTREAM" "$ROOT_DIR/playcover-runtime/PlayTools"
verify_license inject "$INJECT_UPSTREAM" "$ROOT_DIR/ThirdParty/inject"
verify_license Yams "$YAMS_UPSTREAM" "$ROOT_DIR/ThirdParty/Yams"

PLAYCOVER_PATCHES="$AUDIT_TEMP/PlayCover.actual"
PLAYTOOLS_PATCHES="$AUDIT_TEMP/PlayTools.actual"
INJECT_PATCHES="$AUDIT_TEMP/inject.actual"
: > "$PLAYCOVER_PATCHES"
: > "$PLAYTOOLS_PATCHES"
: > "$INJECT_PATCHES"

audit_expected_files PlayCover "$PLAYCOVER_UPSTREAM" "$ROOT_DIR" \
  PlayCover ThirdParty/PlayCover/PlayCover "$PLAYCOVER_PATCHES" \
  "${PLAYCOVER_IMPORTED_FILES[@]}"
verify_recorded_patches PlayCover \
  "$ROOT_DIR/ThirdParty/PlayCover/PROVENANCE.md" "$PLAYCOVER_PATCHES"
echo "[upstream-audit] PlayCover local-only integration: PlayCover/Headless/** (headless API facade). Model/PlayApp.swift is an exact audited corresponding-source authority, explicitly excluded from SwiftPM because its GUI class closure is not linked; PlayApp.sign is adapter-traced through entitlement composition and root-last signing. GUI omissions: Views/**, ViewModel/**, Services/**, AppInstaller/Downloader.swift, AppContainer.swift, Store/download/update/keymap/preferences/UI resources and app targets."

audit_expected_files PlayTools "$PLAYTOOLS_UPSTREAM" "$ROOT_DIR" \
  . playcover-runtime/PlayTools "$PLAYTOOLS_PATCHES" \
  "${PLAYTOOLS_IMPORTED_FILES[@]}"
verify_recorded_patches PlayTools \
  "$ROOT_DIR/playcover-runtime/PlayTools/PROVENANCE.md" "$PLAYTOOLS_PATCHES"
echo "[upstream-audit] PlayTools omissions: Editor/**, Keymap/**, Controls/Frontend/**, debug overlay, Discord activity, UI settings/menu/controller code, translations, Xcode project, and GUI resources. The retained loader/screen/touch/PlayChain path is documented in PROVENANCE.md."

audit_expected_files inject "$INJECT_UPSTREAM" "$ROOT_DIR" \
  Injection/Injection ThirdParty/inject/Injection/Injection "$INJECT_PATCHES" \
  "${INJECT_IMPORTED_FILES[@]}"
verify_recorded_patches inject \
  "$ROOT_DIR/ThirdParty/inject/PROVENANCE.md" "$INJECT_PATCHES"
echo "[upstream-audit] inject omissions: its executable target and upstream tests; ios-use links only the pinned Injection library."
echo "[upstream-audit] PASS: remote, commit, license, expected files, imported-source diffs, SwiftPM pins, and recorded local patch sets audited"
