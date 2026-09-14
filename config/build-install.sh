#!/usr/bin/env bash
# Build-time install steps for the shared image stages. Runs on the HOST
# during `docker build`, so it uses the host's network — no sbx policy needed.
# One subcommand per Dockerfile RUN step; cache mounts (apt/npm) are set up
# by the Dockerfile, which is why there's no cache cleanup here.
set -eux

NODE_VERSION=v22.22.1
PNPM_VERSION=10.33.4
TYPESCRIPT_VERSION=5.9.3
TSX_VERSION=4.20.6
PLAYWRIGHT_VERSION=1.58.2
PG_VERSION=17.7        # matches expedition/postgres/Dockerfile (FROM postgres:17.7)
PG_MAJOR=17
PG_PREFIX=/usr/local/pgsql
PG_DATADIR=/var/lib/postgresql/${PG_MAJOR}/main
PG_CRON_VERSION=1.6.4  # matches expedition/postgres/Dockerfile

# `artifacts` stage: official Node (Ubuntu's own lacks amaro/TS-strip
# support), a global TS toolchain, and Playwright's browsers — all baked once
# and COPY --link'ed into every agent image as identical blobs.
cmd_artifacts() {
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
  /opt/node/bin/node -p "process.versions.amaro || (() => { throw new Error('amaro missing') })()"
  rm -rf /opt/node/include /opt/node/CHANGELOG.md \
         /opt/node/lib/node_modules/npm/docs /opt/node/lib/node_modules/npm/man

  # /opt/node-tools, not NPM_CONFIG_PREFIX: the base images already point that
  # at a dir holding agent CLIs. playwright is pinned here to the exact
  # version whose browsers get installed below, or `playwright screenshot`
  # etc. fail with "Executable doesn't exist".
  /opt/node/bin/npm install -g --prefix /opt/node-tools \
      "pnpm@${PNPM_VERSION}" "typescript@${TYPESCRIPT_VERSION}" \
      "tsx@${TSX_VERSION}" "playwright@${PLAYWRIGHT_VERSION}"
  for b in pnpm tsc tsserver tsx playwright; do test -e "/opt/node-tools/bin/$b"; done

  # Playwright has no ubuntu26.04-arm64 build yet and refuses before
  # downloading. Presenting 24.04 is a pure decision-logic workaround — the
  # binaries it then fetches run fine on 26.04's newer glibc.
  export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
  export PATH=/opt/node/bin:$PATH
  cp /etc/os-release /etc/os-release.real
  trap 'mv -f /etc/os-release.real /etc/os-release' EXIT
  sed -i 's/^VERSION_ID="26.04"/VERSION_ID="24.04"/; s/resolute/noble/g' /etc/os-release
  # --only-shell: headless shell (323MB) only, not headed Chromium (602MB) —
  # agents run headless. ffmpeg is bundled for video recording.
  npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --only-shell chromium ffmpeg
  chmod -R a+rX /opt/ms-playwright
}

# `common` stage: wires the copied artifacts onto PATH, builds PostgreSQL 17 +
# pg_cron from source (matching expedition/postgres/Dockerfile), and installs
# xvfb + Chromium's shared libs.
cmd_postgres() {
  for b in node npm npx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
  for b in pnpm tsc tsserver tsx playwright; do ln -sf "/opt/node-tools/bin/$b" "/usr/local/bin/$b"; done
  /usr/local/bin/node -p "process.versions.amaro || (() => { throw new Error('amaro missing') })()"
  /usr/local/bin/tsc --version
  /usr/local/bin/tsx --version
  [ "$(/usr/local/bin/playwright --version)" = "Version ${PLAYWRIGHT_VERSION}" ]

  install -d -o agent -g agent /home/agent/.cache
  ln -s /opt/ms-playwright /home/agent/.cache/ms-playwright

  # Ubuntu 26.04's own archive only ships postgresql-18, and PGDG's apt repo
  # ships .debs built against a real release's exact library versions that
  # 26.04 doesn't have — a genuine cross-release ABI mismatch, not something
  # an os-release spoof can fix. So Postgres itself is compiled from source
  # here, against whatever libssl/libicu/zlib/readline 26.04 actually ships,
  # with a self-managed cluster (initdb + pg_ctl, not postgresql-common).
  export DEBIAN_FRONTEND=noninteractive
  rm -f /etc/apt/apt.conf.d/docker-clean
  apt-get update
  apt-get install -y --no-install-recommends \
      ca-certificates curl openssl \
      build-essential libreadline-dev zlib1g-dev libssl-dev libicu-dev pkg-config \
      bison flex \
      python3-pil \
      xvfb

  curl -fsSL "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2" \
    -o /tmp/postgresql.tar.bz2
  mkdir -p /tmp/postgresql-src
  tar -xjf /tmp/postgresql.tar.bz2 -C /tmp/postgresql-src --strip-components=1
  (
    cd /tmp/postgresql-src
    ./configure --prefix="${PG_PREFIX}" --with-openssl --with-icu --with-readline --with-zlib
    make -j"$(nproc)"
    make install
    cd contrib
    make -j"$(nproc)"
    make install
  )
  rm -rf /tmp/postgresql.tar.bz2 /tmp/postgresql-src
  for b in "${PG_PREFIX}"/bin/*; do ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done

  # pg_cron builds via PGXS against our own pg_config — no "-server-dev"
  # package needed, since building the full source already installs the
  # server headers that package would otherwise ship.
  curl -fsSL "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" \
    -o /tmp/pg_cron.tar.gz
  mkdir -p /tmp/pg_cron
  tar -xzf /tmp/pg_cron.tar.gz -C /tmp/pg_cron --strip-components=1
  (cd /tmp/pg_cron && make PG_CONFIG="${PG_PREFIX}/bin/pg_config" && make install PG_CONFIG="${PG_PREFIX}/bin/pg_config")
  rm -rf /tmp/pg_cron /tmp/pg_cron.tar.gz

  apt-get purge -y --auto-remove build-essential libreadline-dev zlib1g-dev libssl-dev libicu-dev pkg-config bison flex

  # postgresql-common's .deb postinst normally creates this user/layout; do it
  # ourselves since nothing installs it for a from-source build.
  getent group postgres >/dev/null || groupadd -r postgres
  getent passwd postgres >/dev/null \
    || useradd -r -g postgres -d /var/lib/postgresql -s /usr/sbin/nologin postgres
  install -d -o postgres -g postgres /var/lib/postgresql /var/log/postgresql
  install -d -o postgres -g postgres -m 700 "${PG_DATADIR}"

  # Self-signed cert, CN=postgres (matches expedition's own
  # postgres/entrypoint.sh). No CA trust-store wiring needed — expedition's
  # DATABASE_SSL_MODE=require only encrypts, it never verifies.
  install -d -o postgres -g postgres -m 700 /var/lib/postgresql/ssl
  openssl req -new -x509 -days 3650 -nodes -text \
    -out /var/lib/postgresql/ssl/server.crt \
    -keyout /var/lib/postgresql/ssl/server.key \
    -subj "/CN=postgres"
  chmod 600 /var/lib/postgresql/ssl/server.key /var/lib/postgresql/ssl/server.crt
  chown postgres:postgres /var/lib/postgresql/ssl/server.key /var/lib/postgresql/ssl/server.crt

  # Bake the initialized cluster so the first `pg_ctl start` at container boot
  # is just forking the postmaster. --auth=trust: a throwaway dev database
  # (password reset every boot), not a security boundary.
  sudo -u postgres "${PG_PREFIX}/bin/initdb" -D "${PG_DATADIR}" --auth=trust --username=postgres

  # cron.database_name is fixed to 'manifest': this image targets exactly one
  # project, so there's no per-workspace value to plumb in at runtime.
  cat >> "${PG_DATADIR}/postgresql.conf" <<EOF

# --- baked by config/build-install.sh ---
listen_addresses = 'localhost'
shared_preload_libraries = 'pg_stat_statements,pg_cron'
cron.database_name = 'manifest'
ssl = on
ssl_cert_file = '/var/lib/postgresql/ssl/server.crt'
ssl_key_file = '/var/lib/postgresql/ssl/server.key'
EOF

  # Chromium's own shared libs (the binary itself was baked in `artifacts`).
  # Playwright has no package map for "ubuntu26.04" and silently no-ops there;
  # present 24.04 again, then assert the libraries actually resolve.
  cp /etc/os-release /etc/os-release.real
  sed -i 's/^VERSION_ID="26.04"/VERSION_ID="24.04"/; s/resolute/noble/g' /etc/os-release
  /usr/local/bin/playwright install-deps chromium-headless-shell
  mv -f /etc/os-release.real /etc/os-release
  if ldd /opt/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell | grep "not found"; then
    echo "headless_shell is missing shared libraries — install-deps skipped this distro?" >&2
    exit 1
  fi
}

case "${1:-}" in
  artifacts) cmd_artifacts ;;
  postgres)  cmd_postgres ;;
  *) echo "usage: build-install.sh artifacts|postgres" >&2; exit 2 ;;
esac
