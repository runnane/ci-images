# ci-images

Container images for the **self-hosted GitHub Actions runners** used by the private
`runnane` repos. Tracked in the **CIIMG** project.

Published to public GHCR:

| Image | Contents | Issue |
| --- | --- | --- |
| `ghcr.io/runnane/ci-runner-base` | official runner + `gh` | CIIMG-1 |
| `ghcr.io/runnane/ci-runner-node` | base + Node 20/22/26 in the tool cache + pnpm | CIIMG-2 |

**`ci-runner-node` is the one the runners should use** — it inherits the base, and it
serves all four private repos. There is deliberately **no separate ansible image**
(CIIMG-3, cancelled): the ansible repo needs only Node 20 baked, for its Prettier job,
and everything else in its CI comes from pinned actions — `./.github/actions/uv-env`
(uv 0.11.8, Python 3.14 from `.python-version`), which exists precisely so CI and the
control node run byte-identical versions. Baking `ansible-lint` or `uv` here would
duplicate or fight that. `gitleaks/gitleaks-action@v2` is a JS action (`using: node24`),
not a Docker one, so it needs no daemon inside the runner.

Current digests to pin (read from the `9f3e1cb` publish run's summary — see below for
why the node line will already be stale by the time this PR merges):

```
ghcr.io/runnane/ci-runner-base@sha256:a02422c715e14e38cacab123a4f03165af46d098851447f791e0604f63f93b00
ghcr.io/runnane/ci-runner-node@sha256:1a9726d25128c24e1b3406e44e868457f951edd17ec36363cc051d0b40741d23
```

## Why this repo is public, and must stay that way

Not a philosophical choice — it is the only configuration that works:

- The `runnane` account is a **User account on the free plan**: 2,000 Actions minutes a
  month for *private* repos, which are exhausted within a day or two of each reset. That
  is what forces self-hosted runners in the first place (**ANS-315**).
- **Public repos get free unlimited hosted minutes**, and **public GHCR packages are free**
  for storage and transfer. So this pipeline costs nothing.
- Critically, it keeps building **on GitHub-hosted runners**. If it ran on the
  self-hosted runners, a broken runner image could not be fixed by rebuilding it — you
  would need the thing you broke in order to repair it. `runs-on: ubuntu-latest` in
  [`build.yml`](.github/workflows/build.yml) is load-bearing; don't "optimise" it onto
  the self-hosted fleet.

Nothing in here is sensitive. Nothing in here may *become* sensitive: **image layers are
world-readable and effectively permanent**, so a credential committed to a layer is
leaked for good even after the tag is deleted. The runner registration PAT lives on the
runner host in `/etc/gh-runner/env` (mode 0600, root-owned) and never in an image.

## Consuming an image: pin by digest

```
ghcr.io/runnane/ci-runner-base@sha256:<digest>
```

**Never pin by tag.** A tag moves; a digest does not. These containers execute untrusted
third-party code — a Dependabot version bump's `postinstall` runs inside them, on
hardware on our own network — so what executes must only change via a reviewed commit and
a deliberate digest bump in the [ANS runner role](https://github.com/runnane/ansible).

Every pushed build prints the digest to pin in its workflow run summary.

**Read the digest from the run summary, or from the version tagged `main`.** Do **not**
take "the newest version" out of the GHCR API: attestation manifests are listed alongside
real images and their tag is `sha256-<subject-digest>`, so a naive pick lands on one about
half the time. That happened during CIIMG-6 — the runner role was pinned to an attestation
tag, pulled a digest resolving to the pre-fix layer, and the bug it was meant to fix
reproduced *after a converge that reported `changed`*. Ignore anything whose only tag
matches `sha256-*`, and verify by pulling the candidate before you pin it.

Images are anonymously pullable; no registry credential is needed on the runner host.

**A base-image change reaches `ci-runner-node` as two publishes, not one.** `main`
publishes each image independently, so bumping `ci-runner-base`'s digest does not by
itself rebuild `ci-runner-node` — its `FROM` is a separate pin that has to move too.
Dependabot now watches both `/images/ci-runner-base` and `/images/ci-runner-node`, so
the second bump normally arrives as its own PR shortly after the first merges; a human
can also make it by hand. `.agents/gates.md` calls this the base-then-bump sequence —
see it for how to build both together locally before either publishes.

## What the official base already gives you

Probed from `ghcr.io/actions/actions-runner` on 2026-08-04 (Ubuntu 24.04.4 LTS):

- **present:** `git`, `python3`, `jq`, `curl`, `unzip`, `tar`, `sudo`, `config.sh`,
  `run.sh`, and `--ephemeral` support
- **absent:** `node`, `npm`, `gh`

That gap is the entire reason this repo exists. A self-hosted runner container ships
almost none of what `ubuntu-latest` preinstalls, so workflows that silently assume a tool
is present break on arrival. `respawn-control`'s `dependabot-auto-merge.yml` is the
canonical example: it calls `gh pr merge` directly, which is why **`gh` is in the shared
base** rather than in one consumer image.

Use [`actions/runner-images`](https://github.com/actions/runner-images) as the reference
for what else `ubuntu-latest` provides when a workflow turns out to depend on something
not listed here.

`node`/`npm` are deliberately **not** in the base: consumers disagree on version
(spond-js needs ≥ 22.12, the VTK site ≥ 26), so they belong in the per-image layers.

Also absent and worth knowing: **`xz`**. That is why `ci-runner-node` fetches Node as
`.tar.gz` rather than the smaller `.tar.xz` — a slightly larger download beats adding a
package to a layer every image inherits.

## `ci-runner-node`: the tool cache is the whole point

**Read this before editing that Containerfile.** The value of the image is not that Node
is installed — it is *where* it is installed.

Every consumer gets Node from `actions/setup-node`, which resolves a requested version
against the runner tool cache (`RUNNER_TOOL_CACHE` = `/opt/hostedtoolcache`) and downloads
only on a miss. **A Node binary merely on `PATH` is invisible to it.** So the image seeds
the cache in the exact layout `@actions/tool-cache` expects:

```
/opt/hostedtoolcache/node/<full-version>/x64            the extracted tree
/opt/hostedtoolcache/node/<full-version>/x64.complete   marker — REQUIRED
```

**Without the `.complete` marker the directory is ignored entirely** and `setup-node`
downloads anyway, silently undoing the whole point while everything still passes. If you
add or move a version, add its marker, and keep the assertion block at the end of the
Containerfile that checks for both.

### Which versions, and why exactly these

| Version | Requested by |
| --- | --- |
| **20.20.2** | the ansible repo's Prettier job (`node-version: "20"`, pnpm 9) |
| **22.23.2** | spond-js and respawn-control (`node-version: 22`) |
| **26.6.0** | the VTK site (`engines.node: ">=26"`) — also the default on `PATH` |

Each entry is ~100 MB. **An entry exists because a consumer pins that version** — read
their workflows before adding one, and don't add speculatively. 26 is the `PATH` default
because it satisfies both spond-js (≥ 22.12) and VTK (≥ 26), so one default beats
per-major image variants.

pnpm 10.34.5 is installed globally (spond-js's pin). Repos pinning something else — VTK's
10.33.3, ansible's 9 — still resolve their own via `packageManager` or
`pnpm/action-setup`; the baked copy just makes the common case need no network.

### Two traps found while building it

- **Node 26 needs `libatomic.so.1`**, which the runner base does not ship; its binary dies
  with a loader error. Node 20 and 22 are unaffected — so this breaks *only* the newest
  consumer, and looks fine until VTK's first run. Hence the `libatomic1` layer.
- **Node 26 no longer ships `corepack`** (20 and 22 still do). pnpm therefore comes from
  `npm install -g`, not `corepack prepare` — a corepack-based install would break on
  exactly the consumer that needs the newest Node.
- Related: **npm's global prefix is the node tree itself**, so per-binary symlinks left
  `pnpm` installed but unreachable. The default Node's `bin` is on `PATH` instead, which
  also covers anything installed globally later.

## Adding an image

1. `images/<name>/Containerfile`, starting `FROM ghcr.io/runnane/ci-runner-base@sha256:…`
2. Add `<name>` to the matrix in [`build.yml`](.github/workflows/build.yml)
3. Pin every tool version; no `latest`, no unpinned `apt install` of a moving target
4. End with a check that fails the build if an expected tool is missing — a broken image
   should fail here, not in a consumer's CI at an inconvenient hour
5. Open a PR: it builds without pushing, so the Containerfile is verified before anything
   is published
6. **Build it locally first.** Every problem in `ci-runner-node` — the missing `xz`, Node
   26's `libatomic`, corepack's absence, npm's global prefix — surfaced in a local
   `docker build`, in seconds, before a single CI cycle or a published bad layer. The PR
   build is the second opinion, not the first.
7. **Run a real consumer's gates inside the image** before switching any repo to
   `runs-on: self-hosted`. For `ci-runner-node` that was spond-js's full `pnpm gates`
   (biome, typecheck, build, vitest + coverage) — green, on Node 26.6.0 / pnpm 10.34.5.
   Note the container runs as uid 1001, so a bind-mounted checkout needs matching
   ownership or `pnpm install` silently writes nothing.

## Conventions

- **Digest-pinned bases**, tool versions pinned by `ARG`
- **Jobs run as the unprivileged `runner` user** (uid 1001), never root
- **Weekly scheduled rebuild** so base security updates land deliberately
- **Build provenance attested** on every push, giving a verifiable digest → workflow →
  commit chain
- **Dependabot** watches the Containerfiles and the workflow actions
