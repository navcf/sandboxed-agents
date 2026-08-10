#!/bin/sh
# Append the custom settings block (config/codex-config.toml, baked to
# /usr/local/share/sbx/codex-config.toml) to ~/.codex/config.toml. Guarded on
# the block's marker (first) line, since sbx rewrites the file at every
# sandbox (re)create. Same append-never-rewrite rationale as
# gitnexus-mcp-codex.sh.
set -eu
cfg="$HOME/.codex/config.toml"
src=/usr/local/share/sbx/codex-config.toml
mkdir -p "$(dirname "$cfg")"
touch "$cfg"
marker=$(head -n 1 "$src")
if ! grep -qFx "$marker" "$cfg"; then
  { echo; cat "$src"; } >> "$cfg"
fi
