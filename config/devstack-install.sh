#!/usr/bin/env bash
# Build-time install of the sandbox dev stack. Sourced by every agent Dockerfile
# so claude/codex/cursor sandboxes are identical.
#
# Runs during `docker build` on the HOST, so it uses the host's network — the
# sbx network policy does not apply here. Nothing in this file needs an
# `sbx policy allow`.
#
# Installs:
#   1. An official Node.js build. The base image's Ubuntu `nodejs` is compiled
#      WITHOUT amaro, so `node foo.ts` fails outright.
#   2. PostgreSQL 18 + pg_cron, with a server cert that actually names localhost.
#   3. pnpm, a global TypeScript toolchain, Chromium's system libraries,
#      ffmpeg, xvfb.
#
# Runtime lifecycle lives in the `devstack` helper (installed to /usr/local/bin),
# which is project-agnostic and configured per workspace via `.devstack.conf`.
#
# Version pins: align these with whichever project you work on most, so a
# fallback invocation cannot silently differ from that project's CI.
set -eux

NODE_VERSION=v22.22.1
PNPM_VERSION=10.33.4
PG_MAJOR=18
TYPESCRIPT_VERSION=5.9.3
TSX_VERSION=4.20.6
PLAYWRIGHT_VERSION=1.58.2

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl

# ─────────────────────────────────────────────────────────────────────────────
# 1. Node.js — official build, for TypeScript type stripping
# ─────────────────────────────────────────────────────────────────────────────
# The base image's /usr/bin/node is Ubuntu's package, built without amaro:
#     node -p "process.config.variables.node_use_amaro"   -> false
#     node --experimental-strip-types x.ts                -> ERR_NO_TYPESCRIPT
# Anything that invokes `node some.ts` directly needs this — build scripts,
# codegen, and monorepo tools that resolve `.ts` entrypoints while computing a
# project graph. The failure is confusing rather than obvious: task runners
# report a graph error and every package logs "failed to load config from
# …/vitest.config.ts", i.e. no tests run at all.
# Installed to /opt/node, symlinked ahead of /usr/bin on PATH.
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) NODE_ARCH=x64 ;;
  arm64) NODE_ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz
mkdir -p /opt/node
tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
rm /tmp/node.tar.xz
for b in node npm npx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
# Fail the build here, not three layers later, if the tarball ever ships without it.
/usr/local/bin/node -p "process.versions.amaro || (() => { throw new Error('amaro missing') })()"

# ─────────────────────────────────────────────────────────────────────────────
# 2. PostgreSQL 18 (+ pg_cron)
# ─────────────────────────────────────────────────────────────────────────────
# Native rather than Docker-in-Docker: dev CLIs commonly probe for a local psql
# or pg_isready and only fall back to `docker compose up` when nothing is
# listening, so a native cluster satisfies them with far less machinery.
#
# 18 is what Ubuntu 26.04 ships, straight from main — no third-party repo, and
# postgresql-18-cron is packaged for arm64 as well as amd64. That last point is
# why 18 and not 17: PGDG builds postgresql-17-cron for amd64 only, so pinning 17
# would mean compiling pg_cron from source on every image build on Apple Silicon.
#
# If a project's CI pins a different major, be aware that pg_dump output is not
# identical across majors — don't commit schema dumps generated in a sandbox.
apt-get install -y --no-install-recommends \
    "postgresql-${PG_MAJOR}" \
    "postgresql-${PG_MAJOR}-cron" \
    "postgresql-client-${PG_MAJOR}" \
    ffmpeg xvfb

# Debian/Ubuntu's postgresql.conf already ends with `include_dir = 'conf.d'`, so
# a drop-in wins. `cron.database_name` is deliberately NOT set here: pg_cron is
# cluster-singleton and installs into exactly one database, which is a per-
# workspace choice — `devstack` writes it from .devstack.conf and reloads.
mkdir -p "/etc/postgresql/${PG_MAJOR}/main/conf.d"
cat > "/etc/postgresql/${PG_MAJOR}/main/conf.d/10-devstack.conf" <<'EOF'
shared_preload_libraries = 'pg_stat_statements,pg_cron'
max_connections = 200
ssl = on
ssl_cert_file = '/var/lib/postgresql/ssl/server.crt'
ssl_key_file = '/var/lib/postgresql/ssl/server.key'
EOF

# Apps commonly connect with `?sslmode=require` in a connection string, which
# node-postgres verifies fully — both chain and hostname. Two failure modes:
#   - Ubuntu's ssl-cert-snakeoil cert is named for the container hostname
#     => ERR_TLS_CERT_ALTNAME_INVALID
#   - any untrusted self-signed cert => DEPTH_ZERO_SELF_SIGNED_CERT
# So issue a cert that names localhost and put it in the system trust store (the
# Dockerfile exports NODE_EXTRA_CA_CERTS). This keeps the connection both
# encrypted and verified rather than downgrading to sslmode=disable.
install -d -o postgres -g postgres -m 700 /var/lib/postgresql/ssl
openssl req -new -x509 -days 3650 -nodes -text \
  -out /var/lib/postgresql/ssl/server.crt \
  -keyout /var/lib/postgresql/ssl/server.key \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:postgres,IP:127.0.0.1"
chmod 600 /var/lib/postgresql/ssl/server.key /var/lib/postgresql/ssl/server.crt
chown postgres:postgres /var/lib/postgresql/ssl/server.key /var/lib/postgresql/ssl/server.crt
install -m 644 /var/lib/postgresql/ssl/server.crt /usr/local/share/ca-certificates/devstack-postgres.crt
update-ca-certificates

# ─────────────────────────────────────────────────────────────────────────────
# 3. pnpm + a global TypeScript toolchain + Chromium's shared libraries
# ─────────────────────────────────────────────────────────────────────────────
# Node's built-in support is type STRIPPING, not compilation: it erases
# annotations and never type-checks, and plain `node x.ts` rejects non-erasable
# syntax (enum, parameter properties) — those need
# `node --experimental-transform-types`, which amaro does handle.
#
# So ship a real compiler too. Inside an installed workspace these are redundant:
# `pnpm exec tsc` and `npx tsc` resolve node_modules/.bin first, so a project's
# own pinned typescript/tsx (and tsgo, if it uses one) always wins. The global
# copies are the fallback for everything else — scratch `.ts` files, a repo
# before its install has run, and one-off scripts outside any workspace.
/usr/local/bin/npm install -g \
    "pnpm@${PNPM_VERSION}" \
    "typescript@${TYPESCRIPT_VERSION}" \
    "tsx@${TSX_VERSION}"
for b in pnpm tsc tsserver tsx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
/usr/local/bin/tsc --version
/usr/local/bin/tsx --version
/usr/local/bin/npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium

rm -rf /var/lib/apt/lists/*
