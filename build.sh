#!/usr/bin/env sh
# Build the template image(s) and push to Docker Hub.
# Usage: ./build.sh [claude|codex|cursor|all]   (default: all)
# IMAGE=... overrides the image ref for single-agent builds.
# NAV_SKILLS_SRC=<path> overrides the nav-skills checkout used for the baked
# skill-set floor (default: ../nav-skills beside this repo).
#
# Skills are no longer staged here: they are committed content in
# navcf/nav-skills. That repo is PRIVATE, so the image cannot clone it at build
# time (a credential must never land in a layer) — a local checkout is passed in
# as a named build context instead, and the agent shims fast-forward it over SSH
# at every launch.
set -eu
cd "$(dirname "$0")"

AGENTS=${1:-all}
[ "$AGENTS" = all ] && AGENTS='claude codex cursor'

# The baked floor comes from a local checkout, not a clone. Fail early and
# clearly rather than letting `docker build` complain about a missing context.
SKILLS_SRC=${NAV_SKILLS_SRC:-$(cd .. && pwd)/nav-skills}
[ -d "$SKILLS_SRC/.git" ] || {
  echo "error: no nav-skills checkout at $SKILLS_SRC" >&2
  echo "  clone it (git clone git@github.com:navcf/nav-skills.git) beside this" >&2
  echo "  repo, or set NAV_SKILLS_SRC=<path>." >&2
  exit 1
}
# The floor is whatever the checkout has committed — uncommitted skill edits are
# invisible to the image (COPY brings the worktree, but sync resets to HEAD).
git -C "$SKILLS_SRC" diff --quiet HEAD 2>/dev/null \
  || echo "warn: $SKILLS_SRC has uncommitted changes; the baked floor uses HEAD" >&2

for agent in $AGENTS; do
  case $agent in
    claude) tag=claude-code ;;
    codex)  tag=codex ;;
    cursor) tag=cursor-agent ;;
    *) echo "usage: ./build.sh [claude|codex|cursor|all]" >&2; exit 2 ;;
  esac
  image=${IMAGE:-docker.io/navcf/sandbox-templates:$tag}

  # One Dockerfile, one target per agent. The shared `artifacts` stage builds
  # on the first agent and is a cache hit for the rest.
  docker build --target "$agent" \
    --build-arg "BASE_IMAGE=docker/sandbox-templates:$tag" \
    --build-context "nav-skills=$SKILLS_SRC" \
    -t "$image" .
  docker push "$image"

  echo
  echo "Create a sandbox with:"
  echo "  sbx create -t $image $agent /path/to/workspace"
done
