#!/usr/bin/env sh
# Resolve skills.txt into build/<agent>/ (the Docker build context) using the
# Vercel skills CLI: https://vercel.com/docs/agent-resources/skills
# Usage: ./stage.sh [claude|codex|cursor]   (default: claude)
set -eu
cd "$(dirname "$0")"

AGENT=${1:-claude}
case $AGENT in
  claude) cli_agent=claude-code skills_dir=.claude/skills ;;
  codex)  cli_agent=codex       skills_dir=.agents/skills ;;
  cursor) cli_agent=cursor      skills_dir=.agents/skills ;;
  *) echo "usage: ./stage.sh [claude|codex|cursor]" >&2; exit 2 ;;
esac

dir=build/$AGENT
rm -rf "$dir"
# Pre-create the COPY target so the Docker build survives even if every source
# fails to stage (empty skills dir is a valid, buildable state).
mkdir -p "$dir/$skills_dir"

grep -Ev '^[[:space:]]*(#|$)' skills.txt | while read -r line; do
  # The skills CLI installs under the cwd, so run in build/<agent>/. Rewrite
  # local paths (which are relative to this directory) accordingly.
  case "$line" in
    "~"*) line="$HOME${line#\~}" ;;
    ./* | ../*) line="../../$line" ;;
  esac
  echo "==> skills add $line"
  (cd "$dir" && eval "npx -y skills add $line -a $cli_agent -y --copy" < /dev/null) \
    || echo "warn: no skills staged from: $line" >&2
done

echo
echo "total: $(find "$dir/$skills_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') skills in $dir/$skills_dir"
