#!/usr/bin/env bash
set -euo pipefail

# Skill-only install for Agents, including Linux Consumers. No device setup.
version="${IOS_USE_VERSION:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a value." >&2
        exit 1
      fi
      version="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: install_skill.sh [--version <tag>]"
      echo "Install the local checkout's Skill, or the latest release when run remotely."
      echo "--version (or IOS_USE_VERSION) selects a release instead of the local checkout."
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

skill_dir="${IOS_USE_SKILL_DIR:-$HOME/.ios-use/skill}"
skill_link="${IOS_USE_SKILL_LINK:-$HOME/.agents/skills/ios-use}"
checkout_root="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)"
source_dir="$checkout_root/ios-use-skill"
download_dir=""
cleanup() {
  if [[ -n "$download_dir" ]]; then rm -rf "$download_dir"; fi
}
trap cleanup EXIT

if [[ -n "$version" || ! -f "$source_dir/SKILL.md" ]]; then
  version="${version:-latest}"
  github_repo="${IOS_USE_GITHUB_REPO:-xhzq233/ios-use}"
  if [[ "$version" == "latest" ]]; then
    release_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      "https://github.com/${github_repo}/releases/latest")"
    version="${release_url##*/}"
  fi
  download_dir="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-skill-install.XXXXXX")"
  echo "Downloading ios-use Skill from ${github_repo}@${version}..."
  curl -fsSL "https://codeload.github.com/${github_repo}/tar.gz/${version}" \
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
