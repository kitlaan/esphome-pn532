#!/usr/bin/env bash
#
# tag-release.sh — tag the current HEAD as a pinnable release `<ver>-<rev>`.
#
# `<ver>` is the esphome version main is based on (parsed from the most recent
# `Sync to esphome <ver> ...` commit); `<rev>` is the next integer for that
# version (so a fresh esphome bump starts at -1, and standalone changes against
# the same esphome increment it). Device configs pin `github://.../<repo>@<ver>-<rev>`.
#
# Idempotent: if HEAD is already tagged for this <ver>, it does nothing. This is
# what lets both the sync workflow (which tags itself, because its GITHUB_TOKEN
# push does not trigger the on-push auto-tag workflow) and the auto-tag workflow
# (which handles ordinary pushes/PR merges) call it without double-tagging.
#
# Usage: tag-release.sh [--push]
#   --push   also push the new tag to origin

set -euo pipefail

do_push=false
[ "${1:-}" = "--push" ] && do_push=true

subject="$(git log --grep='^Sync to esphome' -n1 --pretty=%s || true)"
ver="$(printf '%s\n' "$subject" | sed -nE 's/^Sync to esphome ([^ ]+).*/\1/p')"
[ -n "$ver" ] || { echo ">> no 'Sync to esphome' commit reachable from HEAD; nothing to tag" >&2; exit 0; }

# Already tagged for this esphome version at this exact commit? Nothing to do.
if existing="$(git describe --exact-match --match "${ver}-*" HEAD 2>/dev/null)"; then
  echo ">> HEAD already tagged ($existing); skipping"
  exit 0
fi

# Next rev = highest existing <ver>-<n> + 1, else 1. The `|| true` keeps a
# no-match grep (the first tag for this version) from tripping `set -o pipefail`.
last="$(git tag -l "${ver}-*" | sed -E "s/^${ver}-//" | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)"
rev=$(( ${last:-0} + 1 ))
tag="${ver}-${rev}"

git tag -a "$tag" -m "Release $tag (esphome $ver)"
echo ">> tagged $tag"

if $do_push; then
  git push origin "$tag"
  echo ">> pushed $tag"
fi
