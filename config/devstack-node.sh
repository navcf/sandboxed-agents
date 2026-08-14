#!/usr/bin/env bash
# Artifacts-stage download of Node.js + the global TypeScript toolchain.
# Runs ONCE in the Dockerfile's shared `artifacts` stage; every agent image
# copies the results (/opt/node, /opt/node-tools) via COPY --link, so the
# layers are identical blobs across claude/codex/cursor — built once, pushed
# once. devstack-install.sh wires them onto PATH inside each agent image.
#
# Runs during `docker build` on the HOST, so it uses the host's network — the
# sbx network policy does not apply here. Nothing in this file needs an
# `sbx policy allow`.
#
# Version pins: align these with whichever project you work on most, so a
# fallback invocation cannot silently differ from that project's CI.
set -eux

NODE_VERSION=v22.22.1
PNPM_VERSION=10.33.4
TYPESCRIPT_VERSION=5.9.3
TSX_VERSION=4.20.6

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
# Fail the build here, not three layers later, if the tarball ever ships without it.
/opt/node/bin/node -p "process.versions.amaro || (() => { throw new Error('amaro missing') })()"

# ~66MB of dead weight. include/ only serves node-gyp with an explicit
# --nodedir=/opt/node — by default node-gyp downloads headers from nodejs.org,
# which sandboxes can't reach anyway, so native rebuilds need prebuilt binaries
# either way. npm's bundled docs/man are never rendered in an image.
rm -rf /opt/node/include /opt/node/CHANGELOG.md \
       /opt/node/lib/node_modules/npm/docs /opt/node/lib/node_modules/npm/man

# ─────────────────────────────────────────────────────────────────────────────
# 2. pnpm + a global TypeScript toolchain
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
#
# --prefix keeps the tools in a self-contained dir to COPY into agent images,
# out of NPM_CONFIG_PREFIX (which in those images already holds agent CLIs).
/opt/node/bin/npm install -g --prefix /opt/node-tools \
    "pnpm@${PNPM_VERSION}" \
    "typescript@${TYPESCRIPT_VERSION}" \
    "tsx@${TSX_VERSION}"
for b in pnpm tsc tsserver tsx; do test -e "/opt/node-tools/bin/$b"; done
