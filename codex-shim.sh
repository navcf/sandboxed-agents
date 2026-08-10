#!/bin/sh
# Installed at /home/agent/.local/bin/codex, which precedes the real
# npm-global binary on PATH (no mv needed, unlike the claude shim).
# Re-asserts config that sbx clobbers when it re-seeds ~/.codex/config.toml
# at sandbox creation, then hands off to the real codex.
sh /usr/local/share/sbx/gitnexus-mcp-codex.sh || echo 'warn: gitnexus MCP registration failed' >&2
sh /usr/local/share/sbx/codex-settings.sh || echo 'warn: custom settings append failed' >&2
exec /usr/local/share/npm-global/bin/codex "$@"
