# esphome-pn532

A fork of ESPHome's `pn532` and `pn532_spi` components with a few local
behavior changes on top (RF reset handling, quieter read-failure logging). It's
packaged as an [external component][ext] so a device can pull it straight from
GitHub without patching an ESPHome install.

[ext]: https://esphome.io/components/external_components.html

## Using it in a device config

Point `external_components` at this repo and pin a release tag:

```yaml
external_components:
  - source: github://kitlaan/esphome-pn532@2026.6.4-1
```

Pin the **tag**, not the bare repo. A bare `github://kitlaan/esphome-pn532`
tracks `main`, which gets rewritten every time it's synced to a new ESPHome
release — so a device would silently pick up a new ESPHome's component code the
next time it builds. A tag never moves, so you decide when a device changes by
bumping the ref.

Tags are `<esphome-version>-<rev>`, e.g. `2026.6.4-1`. The first part is the
ESPHome release the code is based on; `-rev` increments for each change against
that same release (a local bugfix bumps `-1` to `-2`, a new ESPHome resets it to
`-1`).

`tests/build-test.yaml` is a stripped-down config that exercises `pn532_spi`; use
it as a starting point.

## How the repo is laid out

Two branches, with a deliberate split of responsibility:

- **`upstream`** is a pristine mirror of just `esphome/components/pn532` and
  `esphome/components/pn532_spi`, copied out of the ESPHome monorepo and remapped
  to `components/` here. Nothing is hand-edited on this branch — re-syncing it is
  always a clean overwrite. Each commit records where it came from:
  `Sync to esphome <ver> commit @ <hash>`.
- **`main`** is `upstream` plus the local patches, kept as a linear rebase on top.
  So `git log upstream..main` and `git diff upstream main` show exactly what this
  fork changes.

I went with rebase (rather than merging upstream in) because the patch set is
small and the "ESPHome + my few commits on top" view is worth keeping. The
downside — rebasing rewrites `main`'s history — is handled by pinning device
configs to tags rather than to `main`.

## Keeping it current

`scripts/sync-upstream.sh` does the whole update locally and never pushes:

1. Fetch the latest stable ESPHome release (or a ref you pass as an argument).
2. Mirror the two component dirs onto `upstream` and commit.
3. Rebase `main` onto the new `upstream` in a temp `rebase-upstream` branch.
4. Build-gate it: compile `tests/build-test.yaml` against the rebased tree.
5. Only if the rebase is clean *and* it compiles, fast-forward `main` to the
   result. Otherwise it stops and leaves things for you to sort out — a rebase
   conflict is left paused on `rebase-upstream`, a build failure leaves the
   rebased-but-broken branch in place. `main` is never touched on failure.

```sh
scripts/sync-upstream.sh              # sync to latest stable ESPHome
scripts/sync-upstream.sh 2026.7.0     # or a specific ref
```

The build gate (`scripts/build-gate.sh`) runs ESPHome in Docker by default,
pinned to the release being synced (`ghcr.io/esphome/esphome:<ver>`), so what's
tested matches the ESPHome core the code will actually run against. It falls back
to `uvx esphome` if there's no Docker daemon, and `ESPHOME_CMD` overrides both.
The toolchain cache lives in `~/.cache/esphome-pn532` (outside the repo, reused
across runs); it's a few GB.

After a successful run, review `main` and `upstream` and push them yourself.

### Doing it in CI instead

Three workflows in `.github/workflows/` do the same thing on GitHub:

- **`sync-esphome.yml`** — manual "Run workflow" button (no schedule). Runs the
  same `sync-upstream.sh`, then on success force-pushes `main` + `upstream` and
  tags the release. On a conflict or build failure it opens an issue and leaves
  `main` alone.
- **`pr-build.yml`** — compiles the merge result of any PR into `main`, pinned to
  the current ESPHome version. This is the build gate for local development
  changes.
- **`auto-tag.yml`** — tags `<ver>-<rev>` on pushes to `main`. It covers your own
  PR merges; the sync workflow tags itself, because a push made with
  `GITHUB_TOKEN` doesn't trigger the on-push workflow.

## Maintainer notes

A few repo settings this setup assumes:

- The remote needs an `upstream` branch (`git push origin upstream`) for the sync
  workflow to fetch.
- `main` is updated by force-push (rebase rewrites history), so **don't** add
  branch protection or a ruleset that blocks force-pushing `main`. If you ever
  want that protection, switch the sync workflow to a PR-based promote first.
- Set the repo to **rebase-merge only** so development PRs keep `main` linear.
  Make `pr-build` a required status check if you want it to gate merges.
