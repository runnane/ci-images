# ci-images

Container images for the **self-hosted GitHub Actions runners** used by the private
`runnane` repos. Tracked in the **CIIMG** project.

Published to public GHCR:

| Image | Contents | Issue |
| --- | --- | --- |
| `ghcr.io/runnane/ci-runner-base` | official runner + `gh` | CIIMG-1 |
| `ghcr.io/runnane/ci-runner-node` *(not built yet)* | base + Node + pnpm | CIIMG-2 |
| `ghcr.io/runnane/ci-runner-ansible` *(not built yet)* | base + ansible-lint, gitleaks, uv/pytest, prettier | CIIMG-3 |

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

Images are anonymously pullable; no registry credential is needed on the runner host.

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

## Adding an image

1. `images/<name>/Containerfile`, starting `FROM ghcr.io/runnane/ci-runner-base@sha256:…`
2. Add `<name>` to the matrix in [`build.yml`](.github/workflows/build.yml)
3. Pin every tool version; no `latest`, no unpinned `apt install` of a moving target
4. End with a check that fails the build if an expected tool is missing — a broken image
   should fail here, not in a consumer's CI at an inconvenient hour
5. Open a PR: it builds without pushing, so the Containerfile is verified before anything
   is published

## Conventions

- **Digest-pinned bases**, tool versions pinned by `ARG`
- **Jobs run as the unprivileged `runner` user** (uid 1001), never root
- **Weekly scheduled rebuild** so base security updates land deliberately
- **Build provenance attested** on every push, giving a verifiable digest → workflow →
  commit chain
- **Dependabot** watches the Containerfiles and the workflow actions
