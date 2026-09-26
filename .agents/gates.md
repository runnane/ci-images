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

- **hadolint fails only on `error` for now.** The Containerfiles carry three
  standing warnings, printed on every run: DL4006 in both images and DL3008 on
  `libatomic1`. Fixing them changes the published images, so CIIMG-10 tracks
  that and will then raise the threshold to `warning`. A *new* warning in your
  diff is still yours to fix. Read the hadolint output rather than the exit code.

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
  every image on `pull_request` without logging in to GHCR. It pushes, attests
  and runs the layer secret scan only on `main`. A green PR check therefore says
  nothing about the push path.

## Why `liveBoundary` is `rsync-deploy`

**Merging to `main` publishes.** `build.yml` pushes every image to public GHCR,
tagged `main` and `sha-<commit>`. Those layers are world-readable and effectively
permanent, so a credential that reaches one is leaked for good.

The fleet only picks up a new image when someone bumps the digest in the
ansible runner role, which is a reviewed change in another repo. So the reach of
a merge here is a public publish, not the running runners.

The schema has no member for publishing to a registry, and `none` is the
dangerous way to be wrong: an agent reading `none` concludes a merge is
harmless. `rsync-deploy` names the wrong mechanism, deploy-by-copy, but the
right reach: a merge makes something live and public. That is the direction
constitution §7 says to err in. RCP-1291 asks for a proper member.
