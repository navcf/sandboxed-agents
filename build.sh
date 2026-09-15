#!/usr/bin/env sh
# Build the template image(s) and push to a registry.
# Usage: SBX_TEMPLATE_IMAGE=<registry>/<namespace>/sandbox-templates \
#          ./build.sh [claude|codex|all]   (default: all)
# IMAGE=<full-ref> overrides the image ref for a single-agent build instead.
#
# Bakes a dev stack targeting one project workspace, configured at sandbox
# creation via SBX_WORKSPACE — see the Dockerfile and README.
set -eu
cd "$(dirname "$0")"

AGENTS=${1:-all}
[ "$AGENTS" = all ] && AGENTS='claude codex'

for agent in $AGENTS; do
  case $agent in
    claude) tag=claude-code ;;
    codex)  tag=codex ;;
    *) echo "usage: ./build.sh [claude|codex|all]" >&2; exit 2 ;;
  esac
  image=${IMAGE:-${SBX_TEMPLATE_IMAGE:+$SBX_TEMPLATE_IMAGE:$tag}}
  [ -n "$image" ] || { echo "./build.sh: set SBX_TEMPLATE_IMAGE=<registry>/<namespace>/sandbox-templates (or IMAGE=<full-ref> for a single-agent build)" >&2; exit 1; }

  # Force claude's native-installer RUN / codex's npm RUN to actually
  # re-execute every build: their command text never changes, so without a
  # fresh value here they're a permanent cache hit and never pick up a newer
  # release. See Dockerfile's CLAUDE_CACHE_BUST / CODEX_CACHE_BUST.
  cachebust_args=
  case $agent in
    claude) cachebust_args="--build-arg CLAUDE_CACHE_BUST=$(date +%s)" ;;
    codex)  cachebust_args="--build-arg CODEX_CACHE_BUST=$(date +%s)" ;;
  esac

  # One Dockerfile, one target per agent. The shared `artifacts` stage builds
  # on the first agent and is a cache hit for the rest.
  docker build --target "$agent" \
    --build-arg "BASE_IMAGE=docker/sandbox-templates:$tag" \
    $cachebust_args \
    -t "$image" .
  docker push "$image"

  echo
  echo "Create a sandbox with:"
  echo "  sbx create -e SBX_WORKSPACE=\$SBX_WORKSPACE -t $image $agent \$SBX_WORKSPACE"
done
