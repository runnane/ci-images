#!/usr/bin/env bash
# The gate for this repo — everything that must be green before a PR. See
# .agents/gates.md for what each step is worth and the traps.
#
# There is no package manager here. The linters run as containers, pinned by
# tag, so the only host dependency is docker.
#
# Usage:
#   scripts/gates.sh              manifest → hadolint → actionlint → shellcheck → build
#   scripts/gates.sh --no-build   everything except the image builds
set -euo pipefail

cd "$(dirname "$0")/.."

NO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --no-build) NO_BUILD=1 ;;
    -h|--help)
      echo "usage: scripts/gates.sh [--no-build]"
      exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

HADOLINT=hadolint/hadolint:v2.12.0
ACTIONLINT=rhysd/actionlint:1.7.7
SHELLCHECK=koalaman/shellcheck:v0.10.0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# Every image directory, so a new image is gated without editing this file.
mapfile -t IMAGES < <(find images -mindepth 2 -maxdepth 2 -name Containerfile -printf '%h\n' | xargs -n1 basename | sort)
[ "${#IMAGES[@]}" -gt 0 ] || { echo "!! no images/*/Containerfile found" >&2; exit 1; }

step "manifest (.agents/repo.json)"
# The canonical validator is zod in respawn-control (src/shared/repo-manifest.ts),
# which this repo cannot import. This is the structural half — every required
# key present, no unknown key, enums from that schema — so a typo fails here
# rather than taking the whole manifest to null in instructions_registry.
docker run --rm -i ghcr.io/jqlang/jq:1.7.1 -e '
  def req: ["repo","trackerKey","trackerSlug","visibility","gates","release","ci","liveBoundary","worktreeSafe","userspaceBundle"];
  def opt: ["deepDives","gatesDoc"];
  . as $m
  | (keys - (req + opt)) as $unknown
  | (req - keys) as $missing
  | if ($unknown | length) > 0 then error("unknown keys: \($unknown)")
    elif ($missing | length) > 0 then error("missing keys: \($missing)")
    elif (.gates | type) != "object" or (.gates.all | type) != "string" then error("gates.all must be a string")
    elif ((.gates | keys) - ["all","fix","quick"] | length) > 0 then error("unknown gates keys")
    elif (["public","private"] | index($m.visibility)) == null then error("visibility")
    elif (["changesets","release-it","release-please","np","none"] | index($m.release)) == null then error("release")
    elif (["self-hosted","github-hosted","dispatch-only","none"] | index($m.ci)) == null then error("ci")
    elif (["none","fleet","printer","shell","rsync-deploy","worker-deploy","hosted-service"] | index($m.liveBoundary)) == null then error("liveBoundary")
    elif (.worktreeSafe | type) != "boolean" then error("worktreeSafe must be a boolean")
    else "manifest ok" end
' < .agents/repo.json

step "hadolint (${IMAGES[*]})"
for image in "${IMAGES[@]}"; do
  echo "-- images/$image/Containerfile"
  docker run --rm -i "$HADOLINT" hadolint --failure-threshold warning - < "images/$image/Containerfile"
done

step "actionlint (.github/workflows)"
docker run --rm -v "$PWD:/repo:ro" -w /repo "$ACTIONLINT" -color

step "shellcheck (scripts)"
docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$SHELLCHECK" scripts/*.sh

if [ "$NO_BUILD" = "1" ]; then
  step "docker build — SKIPPED (--no-build); CI still builds every image on the PR"
  printf '\n\033[1;33mgates green, builds skipped\033[0m\n'
  exit 0
fi

# Each run builds under its OWN tag, then removes it: two concurrent runs from
# different worktrees must never test each other's image.
RUN_ID="gates-$$"
cleanup() {
  for image in "${IMAGES[@]}"; do
    docker rmi "ci-images/$image:$RUN_ID" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

for image in "${IMAGES[@]}"; do
  # The build IS the smoke test: every Containerfile ends with a RUN that
  # asserts the tools its consumers rely on, so a broken image fails here.
  step "docker build images/$image"
  docker build --pull \
    -f "images/$image/Containerfile" \
    -t "ci-images/$image:$RUN_ID" \
    "images/$image"
done

printf '\n\033[1;32mgates green\033[0m\n'
