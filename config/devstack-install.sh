#!/usr/bin/env bash
# Per-agent install of the sandbox dev stack. Run by every agent target in the
# Dockerfile so claude/codex/cursor sandboxes are identical.
#
# The heavy, agent-agnostic pieces — official Node.js build, global TypeScript
# toolchain, Playwright browsers, rtk — are downloaded ONCE in the Dockerfile's
# shared `artifacts` stage (devstack-node.sh, install-browsers.sh) and
# COPY --link'ed in before this script runs. This script only wires those into
# place and installs what genuinely must be apt-installed per image:
# PostgreSQL 18 + pg_cron, xvfb, and Chromium's shared libraries.
#
# Runs during `docker build` on the HOST, so it uses the host's network — the
# sbx network policy does not apply here. Nothing in this file needs an
# `sbx policy allow`.
#
# The Dockerfile runs this with apt + npm cache mounts so downloads are shared
# across the three agent builds; that's why there is no
# `rm -rf /var/lib/apt/lists` here — the lists live in the mount, not the layer.
#
# Runtime lifecycle lives in the `devstack` helper (installed to /usr/local/bin),
# which is project-agnostic and configured per workspace via `.devstack.conf`.
set -eux

PG_MAJOR=18
PLAYWRIGHT_VERSION=1.58.2

export DEBIAN_FRONTEND=noninteractive

# ─────────────────────────────────────────────────────────────────────────────
# 1. Wire the shared artifacts into place
# ─────────────────────────────────────────────────────────────────────────────
# Official Node ahead of Ubuntu's amaro-less /usr/bin/node (see devstack-node.sh
# for why). The TS toolchain lives in its own prefix, /opt/node-tools: the base
# images set NPM_CONFIG_PREFIX to a dir that already holds agent CLIs, so the
# shared tools are kept apart from it rather than merged into it.
for b in node npm npx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
for b in pnpm tsc tsserver tsx playwright; do ln -sf "/opt/node-tools/bin/$b" "/usr/local/bin/$b"; done
# Fail here, not at first use, if the copied artifacts are broken.
/usr/local/bin/node -p "process.versions.amaro || (() => { throw new Error('amaro missing') })()"
/usr/local/bin/tsc --version
/usr/local/bin/tsx --version
# The global CLI must match the baked browsers exactly, or one-off commands
# like `playwright screenshot` die with "Executable doesn't exist".
[ "$(/usr/local/bin/playwright --version)" = "Version ${PLAYWRIGHT_VERSION}" ]

# Playwright resolves browsers at ~/.cache/ms-playwright by default; point that
# at the shared root-owned copy. install -d (rather than letting a Dockerfile
# COPY create it) keeps ~/.cache agent-owned for everything else that caches
# there; ln -s fails loudly if a base image ever ships its own browsers.
install -d -o agent -g agent /home/agent/.cache
ln -s /opt/ms-playwright /home/agent/.cache/ms-playwright

# ─────────────────────────────────────────────────────────────────────────────
# 2. PostgreSQL 18 (+ pg_cron), xvfb
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
#
# No apt ffmpeg: the package drags in ~400MB of codec/SDL/mesa/LLVM deps, and
# Playwright video recording doesn't need it (it bundles its own ffmpeg in
# /opt/ms-playwright). If a workload needs the ffmpeg CLI, bake a static build
# in the artifacts stage instead of reintroducing the apt package.
#
# python3-pil (a few MB; python3 is already in the base image) is the image
# tool: without it, cropping/inspecting an existing screenshot requires a
# second live page load with hand-computed clip boxes. Deliberately not
# imagemagick — same weight argument as ffmpeg.
#
# docker-clean would delete downloaded .debs; keep them for the cache mount.
rm -f /etc/apt/apt.conf.d/docker-clean
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates openssl \
    "postgresql-${PG_MAJOR}" \
    "postgresql-${PG_MAJOR}-cron" \
    "postgresql-client-${PG_MAJOR}" \
    python3-pil \
    xvfb

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
# 3. Chromium's shared libraries
# ─────────────────────────────────────────────────────────────────────────────
# The browser binaries were baked in the artifacts stage; this installs only
# their system library dependencies, which must be apt-installed in each image.
#
# Playwright 1.58 has no package map for "ubuntu26.04", and install-deps
# SILENTLY no-ops there — "Cannot install dependencies …!" with exit code 0,
# leaving chromium unable to load libatk & co at runtime. Present 24.04 for the
# duration (same dance as install-browsers.sh; the noble package list installs
# fine on 26.04), then assert every library actually resolves.
cp /etc/os-release /etc/os-release.real
sed -i 's/^VERSION_ID="26.04"/VERSION_ID="24.04"/; s/resolute/noble/g' /etc/os-release
/usr/local/bin/playwright install-deps chromium-headless-shell
mv -f /etc/os-release.real /etc/os-release
if ldd /opt/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell | grep "not found"; then
  echo "headless_shell is missing shared libraries — install-deps skipped this distro?" >&2
  exit 1
fi
