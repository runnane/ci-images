# The gates in this repo

`.agents/repo.json` names this file as `gatesDoc`. The shared `gate-failures`
skill covers how to handle a red run in general. This file covers what is
particular to this repo.

## The command

```bash
scripts/gates.sh              # manifest → hadolint → actionlint → shellcheck → docker build (every image)
scripts/gates.sh --no-build   # everything but the builds (the manifest's gates.quick)
```

There is no `pnpm`. The linters run as pinned containers, so the only host
dependency is `docker`. Every image under `images/*/Containerfile` is found
automatically, so adding an image needs no edit here.

## What each step is worth

| Step | Catches | Blind to |
| --- | --- | --- |
| manifest | a missing, misspelled or out-of-enum key in `.agents/repo.json` | a *wrong* value that is still in the enum |
| hadolint | Dockerfile smells, unpinned `apt` patterns, shell mistakes inside `RUN` | whether the image works |
| actionlint | workflow syntax, bad `${{ }}` expressions, shellcheck of `run:` blocks | whether GHCR accepts the push |
| shellcheck | quoting and globbing bugs in `scripts/*.sh` | — |
| docker build | a dead download URL, a removed package, a tool a consumer needs going missing (each Containerfile ends in an assertion `RUN`) | whether a consumer's real workflow is green in the image; that is README step 7 |

## Traps

- **hadolint fails on `warning`.** Two consequences:
  - Every `apt-get install` needs an exact version.
  - Every `RUN` with a pipe relies on the `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`
    line near the top of each Containerfile. Keep that line in any new image.
- **An exact apt pin expires.** Ubuntu keeps only the newest version in
  `noble-updates`, so a pinned version such as `LIBATOMIC1_VERSION` stops
  installing once it is superseded. When a build fails with `Version '…' for
  'libatomic1' was not found`, the upstream package moved. Bump the `ARG` to
  whatever `apt-cache policy libatomic1` shows inside the base image. Nothing is
  broken beyond that. The weekly scheduled build is usually where this surfaces.

- **The manifest check is structural, not the canonical validator.** The source
  of truth is the zod schema in respawn-control, `src/shared/repo-manifest.ts`.
  The jq program here copies its keys and enums. When that schema gains a
  member, this copy goes stale in the *strict* direction: a valid new value is
  refused here. It never lets through a value the schema rejects.
- **`ci-runner-node` does not build on your local `ci-runner-base`.** Its
  `FROM` pins the *published* base by digest. A change to the base, gated
  locally, is therefore **not** exercised by the node build in the same run.
  To test both together, build the base, then temporarily point the node
  image's `FROM` at the local tag, and never commit that. The real
  base-then-bump sequence is two PRs: the base PR merges and publishes, then a
  digest bump follows.
- **`--pull` is deliberate.** It re-resolves the digest-pinned `FROM` against the
  registry, so a digest that has been garbage-collected fails here rather than
  in CI.
- **Each run builds under its own tag** (`ci-images/<image>:gates-<pid>`) and
  deletes it on exit. Two worktrees gating at once would otherwise test each
  other's image.
- **CI is the second opinion, and it does not push on a PR.** `build.yml` builds
  every image on `pull_request` without logging in to GHCR. It pushes and attests
  only on `main`; the layer secret scan (`scripts/scan-layer-history.sh`, run on
  the loaded image) runs on every event. A green PR check therefore says nothing
  about the push path, but does cover the layer scan.
- **The layer scan must fail on no input.** `docker history` on an image that is
  not in the local daemon prints nothing, which an `if ... | grep` reads as
  "clean" (CIIMG-14). The script reads the history outside any `if` and fails on
  a missing image or an empty history. `gates.sh` runs it on each built image.

## Why `liveBoundary` is `registry-publish`

**Merging to `main` publishes.** `build.yml` pushes every image to public GHCR,
tagged `main` and `sha-<commit>`. Those layers are world-readable and effectively
permanent, so a credential that reaches one is leaked for good.

The fleet only picks up a new image when someone bumps the digest in the
ansible runner role, which is a reviewed change in another repo. So the reach of
a merge here is a public publish, not the running runners, and `fleet` would
overstate it.

`registry-publish` (added by RCP-1291) names exactly that: a merge publishes a
public, effectively permanent artifact to a registry. Until it existed this repo
recorded `rsync-deploy`, the wrong mechanism but the right reach, because `none`
is the dangerous way to be wrong (constitution §7).

The jq check in `scripts/gates.sh` carries its own copy of the schema's enums.
When the schema gains a member, add it there before using it here, and only once
the respawn-control build that has it is deployed: the registry parses this
manifest strictly, so an unknown value takes the whole manifest to null.
