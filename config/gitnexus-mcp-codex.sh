#!/bin/sh
# Append the host-side MCP registrations (gitnexus + agent-bridge) to
# ~/.codex/config.toml. Grep-guarded APPEND, never a rewrite: sbx seeds this
# file unconditionally at sandbox creation. Same pattern sbx uses for its own
# mcp-gateway registration.
set -eu
cfg="$HOME/.codex/config.toml"
mkdir -p "$(dirname "$cfg")"
touch "$cfg"
if ! grep -q '^\[mcp_servers\.gitnexus\]' "$cfg"; then
  cat >> "$cfg" <<'EOF'

[mcp_servers.gitnexus]
type = "http"
url = "http://host.docker.internal:4747/mcp"
EOF
fi
if ! grep -q '^\[mcp_servers\.agents\]' "$cfg"; then
  cat >> "$cfg" <<'EOF'

[mcp_servers.agents]
type = "http"
url = "http://host.docker.internal:4748/mcp"
# ask_agent/get_agent_response block only ~50s per call by default (the peer
# runs async on the host), so codex's 60s default tool timeout would suffice —
# 1h is headroom for callers that pass a large explicit wait_seconds.
tool_timeout_sec = 3600
EOF
fi
