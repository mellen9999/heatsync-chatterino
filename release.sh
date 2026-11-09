#!/usr/bin/env bash
# release.sh — build heatsync.zip (a ready-to-drop Plugins/heatsync/ folder) and
# publish it as the github release for the version in info.json.
#
#   ./release.sh           # build dist/heatsync.zip only
#   ./release.sh install   # build, then install into this machine's chatterino
#   ./release.sh publish   # build, then tag + upload as the latest release
#
# the zip holds only what chatterino loads: info.json, the lua modules, LICENSE,
# README. users install from the stable url
# https://github.com/mellen9999/heatsync-chatterino/releases/latest/download/heatsync.zip
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ver=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' info.json)
[ -n "$ver" ] || { echo "release: no version in info.json" >&2; exit 1; }

# never ship what the suites haven't proven
lua5.4 test/harness.lua | tail -1 | grep -qx "ALL PASS" || { echo "release: harness failing" >&2; exit 1; }
for t in t1 t0; do
  TIER=$t lua5.4 test/harness-degrade.lua | tail -1 | grep -qx "ALL PASS ($t)" || { echo "release: degrade $t failing" >&2; exit 1; }
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/heatsync"
cp info.json LICENSE README.md ./*.lua "$stage/heatsync/"
mkdir -p dist
rm -f dist/heatsync.zip
(cd "$stage" && zip -qr - heatsync) > dist/heatsync.zip
echo "built dist/heatsync.zip (v$ver, $(unzip -Z1 dist/heatsync.zip | grep -c '\.lua$') modules)"

# install: the same folder a user unzips, never a link into this checkout (a link
# puts the login token + state files inside the repo, where `git clean` logs you
# out). the plugin's own files (data/ + the *.txt state) carry over; the previous
# install is kept once as .heatsync.prev. close chatterino first.
if [ "${1:-}" = "install" ]; then
  if pgrep -x chatterino >/dev/null; then echo "release: close chatterino first" >&2; exit 1; fi
  plugins=${CHATTERINO_PLUGINS:-$HOME/.local/share/chatterino/Plugins}
  dest=$plugins/heatsync new=$plugins/.heatsync.new prev=$plugins/.heatsync.prev
  mkdir -p "$plugins"
  rm -rf "$new" && mkdir "$new"
  unzip -q dist/heatsync.zip -d "$new"
  if [ -e "$dest" ]; then
    old=$(readlink -f "$dest")
    [ -d "$old/data" ] && cp -a "$old/data" "$new/heatsync/"
    find "$old" -maxdepth 1 -name '*.txt' -exec cp -a {} "$new/heatsync/" \;
    rm -rf "$prev"
    mv "$dest" "$prev"
  fi
  mv "$new/heatsync" "$dest" && rmdir "$new"
  echo "installed v$ver → $dest (previous kept at $prev)"
  exit 0
fi

[ "${1:-}" = "publish" ] || exit 0

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "release: commit first" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release: push main first" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$ver" >/dev/null; then
  echo "release: v$ver already tagged — bump info.json" >&2; exit 1
fi
git tag "v$ver" && git push -q origin "v$ver"
gh release create "v$ver" dist/heatsync.zip --title "v$ver" --latest \
  --notes "install: download heatsync.zip, unzip it into your chatterino Plugins folder, restart chatterino. full steps in the readme."
echo "published v$ver"
