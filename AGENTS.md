# AGENTS.md

Guidance for coding agents (and humans) working in this repo. Follows the
[agents.md](https://agents.md) convention. Start with [`README.md`](README.md):
it explains what the images are for, why the repo is public, and the tool-cache
design. This file only covers what an agent needs on top of that.

Per-repo facts are recorded in [`.agents/repo.json`](.agents/repo.json): the gate
command, `ci`, `release`, `liveBoundary` and the rest. Work is tracked in the
**CIIMG** project.

## Build / test / lint (run before finishing any change)

```bash
scripts/gates.sh            # manifest → hadolint → actionlint → shellcheck → docker build
scripts/gates.sh --no-build # the quick form
```

See [`.agents/gates.md`](.agents/gates.md) for what each step is worth and the
traps. The biggest one: **`ci-runner-node` builds on the published base, not
your local one.**

## Non-negotiable conventions

- **Merging to `main` publishes.** `build.yml` pushes every image to public GHCR
  on every push to `main`. Image layers are world-readable and effectively
  permanent. Nothing internal may appear in a commit, a Containerfile, a
  workflow or an image: no token, no hostname, no LAN address.
- **`build.yml` stays on `runs-on: ubuntu-latest`.** If it ran on the self-hosted
  runners these images feed, a broken image could not be rebuilt. See the README.
- **Pin by digest and by `ARG` version.** No `latest`, no unpinned moving targets.
  Consumers pin images by digest in the ansible runner role. Bumping that pin
  is operator work in the ansible repo, never part of a PR here.
- **Every Containerfile ends with an assertion `RUN`** that fails the build if a
  tool a consumer relies on is missing. Keep it current when you add a tool.
