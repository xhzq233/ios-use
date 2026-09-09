#!/usr/bin/env bash
set -euo pipefail

# Skill-only install for Agents, including Linux Consumers. No device setup.
skill_dir="${IOS_USE_SKILL_DIR:-$HOME/.ios-use/skill}"
skill_link="${IOS_USE_SKILL_LINK:-$HOME/.agents/skills/ios-use}"
checkout_root="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)"
source_dir="$checkout_root/ios-use-skill"
download_dir=""
cleanup() {
  if [[ -n "$download_dir" ]]; then rm -rf "$download_dir"; fi
}
trap cleanup EXIT

if [[ ! -f "$source_dir/SKILL.md" ]]; then
  download_dir="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-skill.XXXXXX")"
  curl -fsSL "https://codeload.github.com/${IOS_USE_GITHUB_REPO:-xhzq233/ios-use}/tar.gz/${IOS_USE_REF:-main}" \
    -o "$download_dir/source.tar.gz"
  archive_skill="$(tar -tzf "$download_dir/source.tar.gz" | sed -n 's@/SKILL.md$@@p' | awk '/\/ios-use-skill$/ && !found {print; found=1}')"
  test -n "$archive_skill"
  tar -xzf "$download_dir/source.tar.gz" -C "$download_dir" "$archive_skill"
  source_dir="$download_dir/$archive_skill"
fi

if [[ -e "$skill_link" && ! -L "$skill_link" ]]; then
  echo "Existing non-symlink preserved: $skill_link. Move it aside before installing." >&2
  exit 1
fi
mkdir -p "$skill_dir" "$(dirname "$skill_link")"
cp -R "$source_dir/." "$skill_dir/"
ln -sfn "$skill_dir" "$skill_link"
echo "Installed ios-use Skill: $skill_link"
