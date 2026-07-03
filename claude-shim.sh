#!/bin/sh
# Installed at /home/agent/.local/bin/claude, replacing the native-install
# launcher symlink, which the Dockerfile moves to claude-real beforehand.
# Re-asserts config that sbx clobbers when it re-seeds ~/.claude.json at
# sandbox creation, then hands off to the real claude.
node /usr/local/share/sbx/gitnexus-mcp.cjs || echo 'warn: gitnexus MCP registration failed' >&2
exec /home/agent/.local/bin/claude-real "$@"
