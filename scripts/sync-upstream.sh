#!/usr/bin/env bash
#
# sync-upstream.sh — refresh the pristine `upstream` branch from esphome and
# rebase `main` onto it, gated on a clean rebase and a successful build.
#
# Repo model:
#   - `upstream` is a hand-off mirror of two esphome component dirs, remapped
#     from esphome's `esphome/components/<c>` to this repo's `components/<c>`.
#     We never edit it by hand, so re-syncing is always a clean overwrite.
#   - `main` is `upstream` plus our custom commits.
#
# Flow:
#   0. Preflight: clean tree, no in-progress rebase, temp branch free.
#   1. Sync `upstream` to the latest stable esphome release tag (or an override).
#   2. Rebase `main` onto `upstream` in a temp branch.
#   3. Build gate: `esphome compile` the local test config on the temp branch.
#   4. Promote: only if 2 and 3 both pass, move `main` to the rebased HEAD.
#
# On rebase conflict the temp branch is left paused mid-rebase for you to
# resolve. On build failure the temp branch is left with the rebase completed.
# In both failure cases `main` is untouched and nothing is ever pushed.
#
# Config (env vars):
#   ESPHOME_REMOTE  esphome git URL     (default: https://github.com/esphome/esphome.git)
#   TEST_CONFIG     build-gate config, repo-relative (default: tests/build-test.yaml)
#   (build-gate knobs BUILD_BACKEND / ESPHOME_IMAGE / ESPHOME_CACHE_DIR / ESPHOME_CMD
#    are consumed by scripts/build-gate.sh, which this delegates the compile to.)
#
# The build gate (scripts/build-gate.sh) defaults to running esphome in Docker
# (exactly as CI does) so local and CI results match; it falls back to uvx when
# there's no daemon. In both cases esphome is pinned to the release we synced.
#
# Usage: scripts/sync-upstream.sh [<esphome-ref>]
#   <esphome-ref>  optional tag/branch to sync to, overriding "latest stable tag"

set -euo pipefail

ESPHOME_REMOTE="${ESPHOME_REMOTE:-https://github.com/esphome/esphome.git}"
TEST_CONFIG="${TEST_CONFIG:-tests/build-test.yaml}"
TEMP_BRANCH="rebase-upstream"

# Single source of truth: the esphome component names we mirror. Their paths in
# esphome (esphome/components/<name>) and here (components/<name>) are derived
# below; the shared `components/` tail is what lets `tar --strip-components=1`
# do the remap.
COMPONENTS=(pn532 pn532_spi)

UPSTREAM_PATHS=() LOCAL_PATHS=()
for _c in "${COMPONENTS[@]}"; do
  UPSTREAM_PATHS+=("esphome/components/$_c")
  LOCAL_PATHS+=("components/$_c")
done

die() { echo "error: $*" >&2; exit 1; }
info() { echo ">> $*"; }

# --- Phase 0: preflight --------------------------------------------------------

repo_root="$(git rev-parse --show-toplevel)" || die "not in a git repo"
cd "$repo_root"

BUILD_GATE="$repo_root/scripts/build-gate.sh"

orig_branch="$(git rev-parse --abbrev-ref HEAD)"

git diff --quiet && git diff --cached --quiet \
  || die "working tree is dirty; commit or stash first"

[ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ] \
  && die "a rebase is already in progress; finish or abort it first" || true

git show-ref --verify --quiet "refs/heads/$TEMP_BRANCH" \
  && die "temp branch '$TEMP_BRANCH' already exists; delete it (git branch -D $TEMP_BRANCH) and retry" || true

git show-ref --verify --quiet refs/heads/main || die "no local 'main' branch"
git show-ref --verify --quiet refs/heads/upstream || die "no local 'upstream' branch"

# --- Phase 1: sync upstream ----------------------------------------------------

if [ $# -ge 1 ]; then
  target_ref="$1"
  info "using explicit esphome ref: $target_ref"
else
  info "resolving latest stable esphome release tag from $ESPHOME_REMOTE"
  target_ref="$(git ls-remote --tags --refs "$ESPHOME_REMOTE" \
    | sed 's#.*refs/tags/##' \
    | grep -E '^[0-9]{4}\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1)"
  [ -n "$target_ref" ] || die "could not determine latest stable esphome tag"
  info "latest stable esphome tag: $target_ref"
fi

info "fetching esphome $target_ref (shallow)"
git fetch --quiet --depth 1 "$ESPHOME_REMOTE" "$target_ref" \
  || die "failed to fetch ref '$target_ref' from $ESPHOME_REMOTE"

esphome_hash="$(git rev-parse --short FETCH_HEAD)"

info "checking out upstream branch"
git checkout --quiet upstream

# Mirror with delete semantics: drop the dirs, then extract fresh from esphome.
# `git archive | tar --strip-components=1` drops the leading `esphome/`.
git rm -rq --ignore-unmatch "${LOCAL_PATHS[@]}"
git archive FETCH_HEAD "${UPSTREAM_PATHS[@]}" \
  | tar -x --strip-components=1 -C "$repo_root"
git add "${LOCAL_PATHS[@]}"

if git diff --cached --quiet; then
  info "upstream already current at $target_ref ($esphome_hash) — no sync commit"
else
  git commit --quiet -m "Sync to esphome $target_ref commit @ $esphome_hash"
  info "committed upstream sync: esphome $target_ref @ $esphome_hash"
fi

# --- Phase 2: rebase main onto upstream in a temp branch -----------------------

info "creating temp branch '$TEMP_BRANCH' from main and rebasing onto upstream"
git branch "$TEMP_BRANCH" main
git checkout --quiet "$TEMP_BRANCH"

if ! git rebase upstream; then
  cat >&2 <<EOF

!! Rebase of main onto upstream hit conflicts.
   The temp branch '$TEMP_BRANCH' is left PAUSED mid-rebase. main is untouched.

   To finish by hand:
     1. resolve conflicts, then:  git rebase --continue   (repeat as needed)
     2. verify the build:         $BUILD_GATE $target_ref
     3. promote to main:          git branch -f main $TEMP_BRANCH && git checkout main && git branch -d $TEMP_BRANCH

   To bail out entirely:
     git rebase --abort && git checkout $orig_branch && git branch -D $TEMP_BRANCH
EOF
  exit 1
fi

# --- Phase 3: build gate -------------------------------------------------------

if ! "$BUILD_GATE" "$target_ref" "$TEST_CONFIG"; then
  cat >&2 <<EOF

!! Build failed after a clean rebase.
   The temp branch '$TEMP_BRANCH' holds the rebased commits (build broken).
   main is untouched.

   Inspect on '$TEMP_BRANCH', fix, and when it compiles, promote to main:
     git branch -f main $TEMP_BRANCH && git checkout main && git branch -d $TEMP_BRANCH
   Or discard:
     git checkout $orig_branch && git branch -D $TEMP_BRANCH
EOF
  exit 1
fi

# --- Phase 4: promote ----------------------------------------------------------

info "rebase clean and build passed — promoting main to '$TEMP_BRANCH'"
git branch -f main "$TEMP_BRANCH"
git checkout --quiet main
git branch -d "$TEMP_BRANCH"

# Return to wherever the user started, if that wasn't main.
if [ "$orig_branch" != "main" ] && git show-ref --verify --quiet "refs/heads/$orig_branch"; then
  git checkout --quiet "$orig_branch"
fi

info "done. main updated locally; nothing pushed. Review, then push when ready."
