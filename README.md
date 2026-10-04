# ci-images

Container images for the **self-hosted GitHub Actions runners** used by the private
`runnane` repos. Tracked in the **CIIMG** project.

Published to public GHCR:

| Image | Contents | Issue |
| --- | --- | --- |
| `ghcr.io/runnane/ci-runner-base` | official runner + `gh` | CIIMG-1 |
| `ghcr.io/runnane/ci-runner-node` | base + Node 20/22/26 in the tool cache + pnpm + zsh | CIIMG-2, CIIMG-15 |
| `ghcr.io/runnane/ci-runner-muxwall` | node + C++ toolchain, tmux 3.7b (from source), Playwright Chromium's OS libraries | CIIMG-8 |

**`ci-runner-node` is the one the runners should use** — it inherits the base, and it
serves all four private repos. The one exception is muxwall's slots, which need
`ci-runner-muxwall` (see [its section](#ci-runner-muxwall-node-plus-what-muxwalls-gates-need)).
There is deliberately **no separate ansible image**
(CIIMG-3, cancelled): the ansible repo needs only Node 20 baked, for its Prettier job,
and everything else in its CI comes from pinned actions — `./.github/actions/uv-env`
(uv 0.11.8, Python 3.14 from `.python-version`), which exists precisely so CI and the
control node run byte-identical versions. Baking `ansible-lint` or `uv` here would
duplicate or fight that. `gitleaks/gitleaks-action@v2` is a JS action (`using: node24`),
not a Docker one, so it needs no daemon inside the runner.

Digests as of the `9f3e1cb` publish, read from its run summary. The node line predates
the node image's move onto this base (CIIMG-12), so the next publish supersedes it —
always take the digest to pin from the latest run summary, as described below:

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

`zsh` (binary only, no recommends) is there for the ansible repo's pytest job, whose
`.zshrc` tests run a real `zsh -f` (CIIMG-15). A job cannot `apt-get install` it itself:
runner slots run with `no-new-privileges`, so `sudo` refuses, and that hardening stays.

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

## `ci-runner-muxwall`: node plus what muxwall's gates need

`FROM` the published `ci-runner-node` digest, so it inherits the tool cache, pnpm and
`gh`. It adds three things muxwall's `pnpm install` and `pnpm gates` need (CIIMG-8, for
DECK-11):

| Addition | Why |
| --- | --- |
| `make`, `g++` (`python3` is already in the base) | `node-pty` has no linux-x64 prebuild, so `pnpm install` compiles it through `node-gyp` |
| **tmux 3.7b**, built from source | the unit suites drive a real tmux on `-L` sockets rather than a mock |
| Playwright Chromium's **OS libraries only** | the e2e phase launches Chromium |
| `iproute2` (for `ss`) | muxwall's tmux-socket sweep uses it to tell a live socket from a leaked one |
| `fonts-dejavu-core` | without it fontconfig resolves `monospace` to a CJK fallback font (WenQuanYi Zen Hei Mono), which skews the glyph metrics muxwall's sizing and layout specs measure |
| `ENV LANG=C.UTF-8` | GitHub-hosted runners set it and the official runner image does not. Without it tmux escapes muxwall's `0x1f` field separator to the literal text `\037` |

**Why a separate image.** The toolchain and tmux are small, but Chromium's library set
is ~89 packages, and no other consumer needs any of it. A separate image keeps every
other repo's runner lean.

**Why tmux is built from source, and why 3.7b.** Ubuntu noble ships tmux 3.4, and 3.4
**crashes** on exactly the sequence muxwall runs for every session: with
`window-size manual` set on the server, the next `new-session -d` kills the server with
`server exited unexpectedly`. Found by running muxwall's gates inside the first build of
this image, which used apt's 3.4: the unit phase went 149 failed / 3560 passed. It was
bisected over muxwall's server options one at a time, and `window-size manual` was the
only one that crashed. 3.7b is the version muxwall records as measured-good (3.5a is
measured-bad), so the image ships that, from the release tarball, checked against its
sha256. The final assertion `RUN` checks the exact version and replays the crashing
sequence. **Do not switch this back to `apt-get install tmux`**, and bump `TMUX_VERSION`
only after muxwall's gates have run green against the new version. The binary goes to
**`/usr/bin/tmux`**, not `/usr/local/bin`: muxwall runs tmux by that absolute path, so a
tmux anywhere else is the same as no tmux.

**Why the browser is not baked.** A baked browser is tied to one `@playwright/test`
version, so every Playwright bump in muxwall would need a rebuild here, a publish and a
digest bump before its CI went green. The image carries only the libraries, installed by
`playwright install-deps chromium` at muxwall's pinned version. muxwall's workflow
downloads the browser itself with `pnpm exec playwright install chromium`, into an
`actions/cache` keyed on the Playwright version. The libraries are installed by
Playwright rather than as a hand-pinned apt list. The Containerfile header gives the
reasoning: the package *list* is pinned by `PLAYWRIGHT_VERSION`, and the published digest
freezes the package versions.

**pnpm.** The inherited pnpm is 10.34.5. muxwall pins `pnpm@11.21.0`, and a plain `pnpm`
switches itself to that version from the `packageManager` field (measured: `pnpm --version`
inside the clone reports 11.21.0). muxwall's `require-pnpm.sh` refuses a major mismatch,
so a workflow that sets `npm_config_manage_package_manager_versions=false` must install
11.x itself. `pnpm/action-setup` does that.

**Runner label: `muxwall`.** Proposed as `self-hosted,linux,x64,muxwall`, so muxwall's
workflow asks with `runs-on: [self-hosted, muxwall]`. This follows the pattern the
`docker` slots use: a distinct label for slots that differ from the default. Today the
ANS runner role has one image for every slot, so these slots also need the role to
support a per-repo image. That, and the digest pin, are operator work in the ansible
repo, not part of a change here.

**How it was verified.** Before the first publish, muxwall's `pnpm install` and full
`pnpm gates` were run in a fresh clone inside the locally built image, as uid 1001.
`node-pty` compiled to `build/Release/pty.node` and spawned a pty. Typecheck, biome,
build and all 3,709 unit cases were green. Each addition in the table above came out of
a red run of that probe, not from reading. The e2e cases still red in this image fail on
muxwall's own assumptions about the host, not on anything the image lacks:

- a `claude` binary on `PATH`. The spec says it fails rather than skips on purpose, and
  with a stub `claude` on `PATH` both affected cases passed;
- a docker daemon, for the `container` Playwright project;
- a readable quota source for the quota-panel case;
- pixel-exact layout assertions calibrated to the dev host's fonts (Noto Sans / Noto Sans
  Mono). Under DejaVu one hover spec's hard-coded 14 px row misses, and one top-bar case
  spills 2 px at 768 px. Installing Noto instead did not fix this; it moved the failures
  to other cases. So these specs need a tolerance, or a row height they measure, rather
  than a font chosen to match one machine.

Those are for muxwall's workflow and specs to settle (DECK-11). The PR for CIIMG-8 has
the logs.

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
