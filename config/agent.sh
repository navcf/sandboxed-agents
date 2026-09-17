#!/usr/bin/env bash
# Baked to /usr/local/bin/sbx-agent. Every runtime (in-container) step lives
# here as one subcommand each, instead of a scatter of small scripts.
#
#   container-init         image ENTRYPOINT: starts Postgres, then execs "$@"
#                          — runs before any agent CLI
#   launch <claude|codex>  what claude-shim.sh/codex-shim.sh delegate to:
#                          re-assert config sbx clobbers, mount role profiles,
#                          bootstrap the schema, migrate, exec the real binary
#   setup-ssh              GitHub-over-SSH key provisioning (also runs from `launch`)
#   codex-settings          appends config/codex-config.toml to ~/.codex/config.toml
#   gitnexus-codex          rewrites the host MCP entries in ~/.codex/config.toml
set -u

# Set at sandbox creation (`sbx create -e SBX_WORKSPACE=...`, as `sbx-agents`
# and the README's manual examples do) to the same absolute path the
# workspace is bind-mounted at, since a container can't otherwise discover
# it.
REPO=${SBX_WORKSPACE:-}
PG_MAJOR=17
PG_DATADIR="/var/lib/postgresql/${PG_MAJOR}/main"
PG_LOG="/var/log/postgresql/postgresql-${PG_MAJOR}-main.log"
# Host-mounted (by `sbx-agents issue`) at the same path inside the sandbox —
# shared across every --clone sandbox, so only the very first one ever pays
# to download a package; every later install links from here instead. A
# bind-mount sandbox, or one created without that mount, just gets an
# ordinary local directory here — same correctness, no sharing.
PNPM_STORE_DIR=${SBX_PNPM_STORE_DIR:-$HOME/.cache/sbx-pnpm-store}

# Replaces a non-IANA inherited TZ (macOS "PDT7") with UTC. sbx forwards the
# host's TZ verbatim, and an invalid zone makes every temporal-polyfill call
# throw "Invalid string: undefined".
fix_tz() {
  if [ -n "${TZ:-}" ] && ! node -e 'Intl.DateTimeFormat().resolvedOptions().timeZone || process.exit(1)' >/dev/null 2>&1; then
    export TZ=UTC
  fi
}

# Copies a host-mounted GitHub deploy key into ~/.ssh (0600, agent-owned —
# bind mounts preserve host ownership, which ssh refuses to use in place) and
# wires ~/.ssh/config + known_hosts. Silent no-op when no key is mounted; see
# README "GitHub over SSH".
setup_ssh() {
  ssh_dir="${HOME}/.ssh"
  key_dst="${ssh_dir}/github_sandbox"

  key_src="${SANDBOX_GITHUB_KEY:-}"
  if [ -z "$key_src" ]; then
    for k in /Users/*/.ssh/sandbox/id_ed25519 /home/*/.ssh/sandbox/id_ed25519; do
      [ -f "$k" ] && { key_src="$k"; break; }
    done
  fi
  [ -n "$key_src" ] && [ -f "$key_src" ] || return 0

  umask 077
  mkdir -p "$ssh_dir"
  cp "$key_src" "$key_dst"
  chmod 600 "$key_dst"
  if [ -f "${key_src}.pub" ]; then
    cp "${key_src}.pub" "${key_dst}.pub"
    chmod 644 "${key_dst}.pub"
  fi

  if ! grep -qs '^github.com ' "${ssh_dir}/known_hosts"; then
    cat /usr/local/share/sbx/github-known-hosts >> "${ssh_dir}/known_hosts"
  fi
  # ssh.github.com:443 is the SSH-over-HTTPS fallback for networks that block
  # port 22 egress (ssh://git@ssh.github.com:443/owner/repo.git).
  if ! grep -qs 'BEGIN sandbox github' "${ssh_dir}/config"; then
    cat >> "${ssh_dir}/config" <<EOF
# BEGIN sandbox github (sbx-agent setup-ssh)
Host github.com
  User git
  IdentityFile ${key_dst}
  IdentitiesOnly yes
Host ssh.github.com
  User git
  Port 443
  IdentityFile ${key_dst}
  IdentitiesOnly yes
# END sandbox github
EOF
  fi
  chmod 600 "${ssh_dir}/config"
}

# Grep-guarded append (never a rewrite — sbx seeds config.toml unconditionally
# at sandbox (re)create) of the custom settings block.
codex_settings() {
  cfg="$HOME/.codex/config.toml"
  src=/usr/local/share/sbx/codex-config.toml
  mkdir -p "$(dirname "$cfg")"
  touch "$cfg"
  marker=$(head -n 1 "$src")
  grep -qFx "$marker" "$cfg" || { echo; cat "$src"; } >> "$cfg"
}

# Idempotent rewrite of the host MCP entries (gitnexus + agent-bridge) in
# ~/.codex/config.toml: strips any existing [mcp_servers.gitnexus]/[mcp_servers.agents]
# blocks (wherever their url/tool_timeout_sec came from — a stale image, a
# manual edit) and re-appends the current values, so a re-run always
# converges instead of leaving a first-seeded block permanently stale.
gitnexus_codex() {
  cfg="$HOME/.codex/config.toml"
  mkdir -p "$(dirname "$cfg")"
  touch "$cfg"
  awk '
    /^\[mcp_servers\.(gitnexus|agents)\]$/ { skip = 1; blank = 0; next }
    /^\[/ { skip = 0 }
    skip { next }
    /^$/ { blank++; next }
    { for (i = 0; i < blank; i++) print ""; blank = 0; print }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  cat >> "$cfg" <<'EOF'

[mcp_servers.gitnexus]
type = "http"
url = "http://host.docker.internal:4747/api/mcp"

[mcp_servers.agents]
type = "http"
url = "http://host.docker.internal:4748/mcp"
tool_timeout_sec = 3600
EOF
}

# Registers /run/sandbox/source (clone mode's live read-only host mount) as
# the `host` remote, and drops the sandbox-* remotes the clone copied from the
# host's config (their URLs are host-loopback ports, dead in here). No-op in
# bind-mount sandboxes or once already registered.
clone_remotes() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  [ -e /run/sandbox/source/.git ] || return 0
  git remote get-url host >/dev/null 2>&1 || git remote add host /run/sandbox/source
  for r in $(git remote | grep '^sandbox-'); do git remote remove "$r"; done
}

# Links the role profiles and the repo's project skills into the workspace's
# .claude/, the only place Claude Code looks for either. The profiles live in
# .agents/profiles/ — gitignored, so absent from a --clone workspace — but the
# host tree is bind-mounted read-only at /run/sandbox/source, so the plugin's
# own mount script is reachable there. Falls back to the workspace itself in
# bind-mount sandboxes, where .agents/profiles/ is present directly. No-op when
# the profiles aren't checked out on the host at all.
#
# Skill links resolve inside the workspace (they're tracked, so the clone has
# them); only the profile links point into the read-only mount, and they are
# only ever read. Everything it writes lands under .claude/, gitignored in the
# clone too, so none of it dirties the agent's branch.
mount_profiles() {
  src=/run/sandbox/source
  [ -d "$src/.agents/profiles" ] || src="$REPO"
  mount=$src/.agents/profiles/plugins/manifest-eng/bin/mount.sh
  [ -f "$mount" ] || return 0
  bash "$mount" "$REPO" --agents
}

# A fresh --clone sandbox is a bare git clone with no node_modules anywhere —
# nothing ever runs `pnpm install` for it otherwise. Always runs (no
# node_modules-exists shortcut: a workspace this size can end up with a
# present-but-incomplete root node_modules from an interrupted install,
# which would otherwise wedge every later launch on the same missing
# package); pnpm's own state check keeps a fully-installed repo's launches
# fast.
ensure_deps() {
  echo "[sbx-agent] syncing workspace dependencies…"
  (cd "$REPO" && pnpm install --frozen-lockfile --store-dir="$PNPM_STORE_DIR") \
    || echo 'warn: pnpm install failed — diagnose with `pnpm install` by hand' >&2
}

# manifest + pgboss schemas, extensions, role GUCs — idempotent, sourced from
# the workspace (never baked) so it can't drift from the project. Run from
# `migrate()`, not container-init: a --clone sandbox's workspace can still be
# populating (git clone + `pnpm install` can take a while) when the
# ENTRYPOINT runs, so bootstrapping there raced an empty checkout and left
# the "manifest" database never created. By the time launch() gets here the
# workspace is guaranteed present — ensure_deps just read files from it.
bootstrap_schema() {
  if [ -f "${REPO}/postgres/init-db.sql" ]; then
    sudo -u postgres psql -q -v ON_ERROR_STOP=1 -f "${REPO}/postgres/init-db.sql" >/dev/null 2>&1 \
      || echo "[sbx-agent] warn: postgres/init-db.sql bootstrap failed — see \`manifest db status\`" >&2
  else
    echo "[sbx-agent] warn: ${REPO}/postgres/init-db.sql not found — is the workspace mounted?" >&2
  fi
}

# Idempotent, non-destructive — safe to run at every launch so a container
# that stays up across many re-attaches still picks up migrations landed
# since the last one. Serialized with flock: two launches racing this (e.g.
# a slow first `pnpm install` still running when a second terminal reattaches)
# would otherwise both reach `pnpm manifest db migrate` at once, and the
# loser gets a confusing Postgres "lock timeout" from the migration runner's
# own advisory lock instead of just waiting its turn.
migrate() {
  (
    flock -w 600 9 || exit 75
    bootstrap_schema
    ensure_deps
    cd "$REPO" && pnpm manifest db migrate
  ) 9>/tmp/sbx-agent-migrate.lock
  case $? in
    0) ;;
    75) echo 'warn: timed out waiting for another launch to finish setting up the workspace — try again shortly' >&2 ;;
    *) echo 'warn: manifest db migrate failed — diagnose with `pnpm manifest db status`' >&2 ;;
  esac
}

# Image ENTRYPOINT (`tini -- sbx-agent container-init -- "$@"`). Starts
# Postgres before ANY agent CLI runs, so `sbx exec` sees it ready too, not
# just whichever agent's shim happens to run. Schema bootstrap happens later,
# in `migrate()` — see its comment for why. Non-fatal by design: a failed
# step warns and falls through to exec.
container_init() {
  fix_tz

  if ! pg_isready -h localhost -p 5432 -q 2>/dev/null; then
    echo "[sbx-agent] starting PostgreSQL ${PG_MAJOR}…"
    sudo -u postgres pg_ctl -D "${PG_DATADIR}" -l "${PG_LOG}" start
    for _ in $(seq 1 30); do
      pg_isready -h localhost -p 5432 -q 2>/dev/null && break
      sleep 1
    done
    if ! pg_isready -h localhost -p 5432 -q 2>/dev/null; then
      echo "[sbx-agent] warn: Postgres did not come up — see \`manifest db status\`" >&2
      sudo tail -30 "${PG_LOG}" >&2 || true
    fi
  fi

  sudo -u postgres psql -qtAc "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 \
    || echo "[sbx-agent] warn: could not set the postgres user's password" >&2

  exec "$@"
}

# What claude-shim.sh / codex-shim.sh delegate to, on EVERY invocation — a
# `sbx run` reattach to an already-running container goes straight through the
# shim via `docker exec`, bypassing container-init entirely, so this can't
# assume anything upstream already ran. Re-asserts config sbx clobbers, then
# execs the real binary.
launch() {
  agent=$1; shift
  fix_tz
  [ -n "$REPO" ] || echo "[sbx-agent] warn: SBX_WORKSPACE not set — pass -e SBX_WORKSPACE=<workspace path> at sandbox creation; dev-stack bootstrap below will likely fail" >&2
  case "$agent" in
    claude)
      node /usr/local/share/sbx/gitnexus-mcp.cjs || echo 'warn: gitnexus MCP registration failed' >&2
      node /usr/local/share/sbx/claude-settings-merge.cjs || echo 'warn: settings merge failed' >&2
      mount_profiles || echo 'warn: role profile mount failed' >&2
      ;;
    codex)
      gitnexus_codex || echo 'warn: gitnexus MCP registration failed' >&2
      codex_settings || echo 'warn: custom settings append failed' >&2
      ;;
    *) echo "usage: sbx-agent launch <claude|codex>" >&2; exit 2 ;;
  esac
  setup_ssh || echo 'warn: github ssh setup failed' >&2
  clone_remotes
  migrate
  case "$agent" in
    claude) exec /home/agent/.local/bin/claude-real "$@" ;;
    codex)  exec /usr/local/share/npm-global/bin/codex "$@" ;;
  esac
}

case "${1:-}" in
  container-init) shift; container_init "$@" ;;
  launch)         shift; launch "$@" ;;
  setup-ssh)      setup_ssh ;;
  codex-settings) codex_settings ;;
  gitnexus-codex) gitnexus_codex ;;
  *) echo "usage: sbx-agent <container-init|launch <claude|codex>|setup-ssh|codex-settings|gitnexus-codex>" >&2; exit 2 ;;
esac
