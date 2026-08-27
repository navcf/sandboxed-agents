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
# Fast-forward the skill set from navcf/nav-skills and materialize it into
# ~/.codex/skills, so a pushed skill change lands without an image rebuild.
# Non-fatal: a failed sync leaves the baked snapshot in place. Codex's own
# built-ins under ~/.codex/skills/.system are never touched.
nav-skills sync || echo 'warn: skills sync failed — using the baked snapshot; diagnose with `nav-skills status`' >&2
# Bring the workspace's dev stack up before the agent starts. devstack up is
# idempotent and non-destructive, so the first launch pays the real cost and
# later launches are a ~1s no-op that also restarts Postgres after a sandbox
# stop/resume. Skipped outside a git workspace; never blocks the launch.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  # Clone mode (--clone): the host repo is mounted live and read-only at
  # /run/sandbox/source — register it as the `host` remote (host updates come
  # in with `git fetch host`), and drop the sandbox-* remotes the clone copied
  # from the host's config (their URLs are host-loopback ports, dead in here).
  # Both are no-ops on later launches and in bind-mount sandboxes.
  if [ -e /run/sandbox/source/.git ]; then
    git remote get-url host >/dev/null 2>&1 || git remote add host /run/sandbox/source
    for r in $(git remote | grep '^sandbox-'); do git remote remove "$r"; done
  fi
  devstack up || echo 'warn: devstack up failed — diagnose with `devstack status`, then `devstack up`' >&2
fi
exec /usr/local/share/npm-global/bin/codex "$@"
