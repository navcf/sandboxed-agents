#!/usr/bin/env sh
# Stage skills, build the template image, and push it to Docker Hub.
set -eu
cd "$(dirname "$0")"

IMAGE=${IMAGE:-docker.io/navcf/sandbox-templates:claude-code}

./stage.sh
docker build -t "$IMAGE" .
docker push "$IMAGE"

echo
echo "Create a sandbox with:"
echo "  sbx create -t $IMAGE claude /path/to/workspace"
