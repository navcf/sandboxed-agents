#!/usr/bin/env sh
# Stage skills, build the template image(s), and push to Docker Hub.
# Usage: ./build.sh [claude|codex|cursor|all]   (default: all)
# IMAGE=... overrides the image ref for single-agent builds.
set -eu
cd "$(dirname "$0")"

AGENTS=${1:-all}
[ "$AGENTS" = all ] && AGENTS='claude codex cursor'

for agent in $AGENTS; do
  case $agent in
    claude) tag=claude-code ;;
    codex)  tag=codex ;;
    cursor) tag=cursor-agent ;;
    *) echo "usage: ./build.sh [claude|codex|cursor|all]" >&2; exit 2 ;;
  esac
  image=${IMAGE:-docker.io/navcf/sandbox-templates:$tag}

  ./stage.sh "$agent"
  docker build -f "Dockerfile.$agent" -t "$image" .
  docker push "$image"

  echo
  echo "Create a sandbox with:"
  echo "  sbx create -t $image $agent /path/to/workspace"
done
