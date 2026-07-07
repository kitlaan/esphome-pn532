#!/usr/bin/env bash
#
# build-gate.sh — compile the build-test config with esphome, pinned to a given
# release. Shared by sync-upstream.sh (the local rebase gate) and CI (the
# pull_request build check), so both validate identically.
#
# It compiles the current working tree: the test config points
# `external_components` at the repo, so whatever is checked out is what's built.
#
# Config (env vars):
#   BUILD_BACKEND      docker | uvx  (default: docker if a daemon is available, else uvx)
#   ESPHOME_IMAGE      docker image repo (default: ghcr.io/esphome/esphome; tag = the ref)
#   ESPHOME_CACHE_DIR  host dir for the docker platformio/toolchain cache, kept out of the
#                      repo (default: ${XDG_CACHE_HOME:-~/.cache}/esphome-pn532)
#   ESPHOME_CMD        override esphome invocation; used verbatim with `compile <cfg>` appended
#
# Usage: build-gate.sh <esphome-ref> [<config>]
#   <esphome-ref>  release version (YYYY.M.P) to pin the esphome build to; a
#                  non-release ref falls back to `latest` with a skew warning.
#   <config>       config to compile (default: $TEST_CONFIG or tests/build-test.yaml)

set -euo pipefail

ref="${1:?usage: build-gate.sh <esphome-ref> [config]}"
config="${2:-${TEST_CONFIG:-tests/build-test.yaml}}"

BUILD_BACKEND="${BUILD_BACKEND:-}"
ESPHOME_IMAGE="${ESPHOME_IMAGE:-ghcr.io/esphome/esphome}"
ESPHOME_CACHE_DIR="${ESPHOME_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/esphome-pn532}"
ESPHOME_CMD="${ESPHOME_CMD:-}"

repo_root="$(git rev-parse --show-toplevel)"

# Pin to the synced release so we build against the matching esphome core. A
# release-style ref maps to a real image tag / PyPI version; anything else has
# no matching pin, so fall back to `latest` and warn about the skew.
pin="$ref"
if ! [[ "$ref" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
  pin="latest"
  echo ">> warning: ref '$ref' is not a release version; build gate uses esphome '$pin' (possible version skew)" >&2
fi

# Prefer docker (matches CI) unless the user forced a backend or docker is absent.
if [ -z "$ESPHOME_CMD" ] && [ -z "$BUILD_BACKEND" ]; then
  if docker info >/dev/null 2>&1; then
    BUILD_BACKEND=docker
  else
    BUILD_BACKEND=uvx
    echo ">> no docker daemon reachable; using uvx build backend" >&2
  fi
fi

if [ -n "$ESPHOME_CMD" ]; then
  read -ra cmd <<< "$ESPHOME_CMD"
  cmd+=(compile "$config")
elif [ "$BUILD_BACKEND" = docker ]; then
  # Mount the repo at /config (the image's workdir + entrypoint `esphome`), so
  # the config's `external_components: path: ..` resolves to the repo root. Run
  # as the host user and point HOME + the image's /cache hook at an out-of-repo
  # cache dir, so the container leaves no root-owned files in the repo and the
  # multi-GB toolchain is reused across runs. The build dir still lands in the
  # git-ignored tests/.esphome, now host-owned.
  mkdir -p "$ESPHOME_CACHE_DIR"
  cmd=(docker run --rm
    -u "$(id -u):$(id -g)" -e HOME=/cache
    -v "$repo_root:/config" -v "$ESPHOME_CACHE_DIR:/cache"
    "$ESPHOME_IMAGE:$pin" compile "$config")
else
  cmd=(uvx "esphome@$pin" compile "$config")
fi

echo ">> build gate: ${cmd[*]}"
exec "${cmd[@]}"
