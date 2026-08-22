#!/bin/sh
# Installed at /home/agent/.local/bin/codex, which precedes the real
# npm-global binary on PATH (no mv needed, unlike the claude shim).
# Re-asserts config that sbx clobbers when it re-seeds ~/.codex/config.toml
# at sandbox creation, then hands off to the real codex.
sh /usr/local/share/sbx/gitnexus-mcp-codex.sh || echo 'warn: gitnexus MCP registration failed' >&2
sh /usr/local/share/sbx/codex-settings.sh || echo 'warn: custom settings append failed' >&2
# Provision GitHub SSH from a host-mounted key, if one was mounted at creation
# (idempotent no-op otherwise) — see README "GitHub over SSH".
sh /usr/local/share/sbx/setup-ssh.sh || echo 'warn: github ssh setup failed' >&2
# Replace a non-IANA inherited TZ (macOS "PDT7") with UTC — see fix-tz.sh.
. /usr/local/share/sbx/fix-tz.sh
# Bring the workspace's dev stack up before the agent starts. devstack up is
# idempotent and non-destructive, so the first launch pays the real cost and
# later launches are a ~1s no-op that also restarts Postgres after a sandbox
# stop/resume. Skipped outside a git workspace; never blocks the launch.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  devstack up || echo 'warn: devstack up failed — diagnose with `devstack status`, then `devstack up`' >&2
fi
exec /usr/local/share/npm-global/bin/codex "$@"
