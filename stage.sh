#!/usr/bin/env sh
# Resolve skills.txt into build/.claude/skills/ (the Docker build context) using
# the Vercel skills CLI: https://vercel.com/docs/agent-resources/skills
set -eu
cd "$(dirname "$0")"

rm -rf build
# Pre-create the COPY target so the Docker build survives even if every source
# fails to stage (empty skills dir is a valid, buildable state).
mkdir -p build/.claude/skills

grep -Ev '^[[:space:]]*(#|$)' skills.txt | while read -r line; do
  # The skills CLI installs into .claude/skills under the cwd, so run in build/.
  # Rewrite local paths (which are relative to this directory) accordingly.
  case "$line" in
    "~"*) line="$HOME${line#\~}" ;;
    ./* | ../*) line="../$line" ;;
  esac
  echo "==> skills add $line"
  (cd build && eval "npx -y skills add $line -a claude-code -y --copy" < /dev/null) \
    || echo "warn: no skills staged from: $line" >&2
done

echo
echo "total: $(find build/.claude/skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') skills in build/.claude/skills"
