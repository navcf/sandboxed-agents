#!/usr/bin/env sh
# Serve the gitnexus MCP server over HTTP for sandboxes to reach via
# host.docker.internal. Loopback bind — no auth token required.
# If sandboxes cannot reach it, retry with: --host 0.0.0.0 --auth-token <token>
set -eu

exec npx -y gitnexus mcp --http -p "${GITNEXUS_MCP_PORT:-4747}"
