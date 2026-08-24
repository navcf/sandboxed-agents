# syntax=docker/dockerfile:1
# Custom Docker Sandboxes templates for Claude Code, Codex, and Cursor.
# Build via ./build.sh [claude|codex|cursor|all] — it stages skills into
# build/<agent>/ (stage.sh, Vercel skills CLI) and then runs
#   docker build --target <agent> --build-arg BASE_IMAGE=docker/sandbox-templates:<tag>
# Everything is baked at build time.
#
# Layout: the `artifacts` stage downloads everything agent-agnostic ONCE (rtk,
# official Node, TS toolchain, Playwright browsers); it takes no build args, so
# all three targets share one cached copy. Each agent target COPY --link's the
# artifacts in — linked layers are parent-independent, so the blobs are
# identical across the three images and are pushed/pulled once. The `devstack`
# stage holds everything else the agents have in common; only its apt work
# (Postgres, xvfb, Chromium libs) runs once per agent, with cache
# mounts so packages download only once per build host.

# No default on purpose: building without build.sh (or without the arg) fails
# loudly instead of silently stacking one agent's config on another's base.
ARG BASE_IMAGE

# ── Shared artifacts — built once, copied into every agent image ─────────────
# Based on the claude-code template rather than bare ubuntu so the userland
# (glibc, os-release) is guaranteed to match the images the artifacts land in.
FROM docker/sandbox-templates:claude-code AS artifacts
USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils

ENV RTK_INSTALL_DIR=/usr/local/bin
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    # Fail the build here (not at rtk init below) if the installer ignored RTK_INSTALL_DIR.
    && /usr/local/bin/rtk --version

# Official Node build + global TS toolchain → /opt/node, /opt/node-tools.
COPY config/devstack-node.sh /tmp/devstack-node.sh
RUN --mount=type=cache,target=/root/.npm \
    sh /tmp/devstack-node.sh

# Playwright browsers → /opt/ms-playwright, so sandboxes need no runtime
# access to cdn.playwright.dev.
COPY config/install-browsers.sh /tmp/install-browsers.sh
RUN sh /tmp/install-browsers.sh

# ── Common dev stack — everything the three agents share ─────────────────────
FROM ${BASE_IMAGE} AS devstack
USER root
COPY --link --from=artifacts /usr/local/bin/rtk /usr/local/bin/rtk
COPY --link --from=artifacts /opt/node /opt/node
COPY --link --from=artifacts /opt/node-tools /opt/node-tools
COPY --link --from=artifacts /opt/ms-playwright /opt/ms-playwright

# PostgreSQL 18 + pg_cron (with a server cert that actually names localhost),
# xvfb, Chromium's system libraries, and PATH wiring for the copied
# artifacts. See config/devstack-install.sh for the reasoning per piece, and
# `devstack` for the per-workspace lifecycle.
COPY config/devstack-install.sh /tmp/devstack-install.sh
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    sh /tmp/devstack-install.sh && rm /tmp/devstack-install.sh
COPY --chmod=755 config/devstack /usr/local/bin/devstack
# Sourced by the agent shims and devstack to replace a non-IANA inherited TZ
# (macOS "PDT7") with UTC before anything date-y runs.
COPY config/fix-tz.sh /usr/local/share/sbx/fix-tz.sh
# GitHub-over-SSH provisioning, run by the shims at every launch: copies a
# host-MOUNTED deploy key into ~/.ssh (a key must never be baked into a layer
# — these images are pushed to a registry) and writes ssh config/known_hosts.
# No-op when no key is mounted. See README "GitHub over SSH".
COPY config/setup-ssh.sh /usr/local/share/sbx/setup-ssh.sh
COPY config/github-known-hosts /usr/local/share/sbx/github-known-hosts
# Progressive-disclosure companions to the baked CLAUDE.md/AGENTS.md: the core
# instruction files stay short and point here for task-specific detail.
COPY config/agent-docs/ /usr/local/share/sbx/docs/

# sbx forwards the host's TZ, and macOS sends abbreviations like "PDT7" — not a
# valid IANA zone. Intl then resolves timeZone to undefined and every
# temporal-polyfill call throws "Invalid string: undefined". ENV loses to a real inherited
# TZ, so also pass `-e TZ=UTC` at sandbox creation.
ENV TZ=UTC
# Trusts the Postgres server cert issued by devstack-install.sh, so
# DATABASE_SSL_MODE=require verifies instead of failing closed.
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/devstack-postgres.crt

# ── Claude Code ───────────────────────────────────────────────────────────────
FROM devstack AS claude
# Sandboxes do NOT sync host ~/.claude — global config and skills must live in the image.
COPY --chown=agent:agent build/claude/.claude/skills /home/agent/.claude/skills
COPY --chown=agent:agent config/CLAUDE.md /home/agent/.claude/CLAUDE.md
# Custom settings baked before rtk init patches its hooks into the same file.
COPY --chown=agent:agent config/claude-settings.json /home/agent/.claude/settings.json

# sbx re-seeds ~/.claude.json at sandbox creation, clobbering anything baked at
# build time. Claude is a native install whose launcher symlink lives at
# /home/agent/.local/bin/claude — move it aside and put a shim in its place that
# re-asserts the gitnexus MCP registration just before the real binary launches.
# The mv fails the build loudly if the base image ever relocates the launcher.
COPY config/gitnexus-mcp.cjs /usr/local/share/sbx/gitnexus-mcp.cjs
COPY config/claude-settings-merge.cjs /usr/local/share/sbx/claude-settings-merge.cjs
RUN mv /home/agent/.local/bin/claude /home/agent/.local/bin/claude-real
COPY --chown=agent:agent --chmod=755 claude-shim.sh /home/agent/.local/bin/claude

USER agent
# Classic builder does not derive HOME from USER; rtk/node below need it.
ENV HOME=/home/agent

# Wire RTK's Claude Code hooks into ~/.claude.
RUN rtk init --global --auto-patch

# Register gitnexus at build time too — covers any launch path that bypasses the
# shim while ~/.claude.json is still the baked one.
RUN node /usr/local/share/sbx/gitnexus-mcp.cjs

# Snapshot the final build-time settings (custom settings + rtk hooks) as the
# launch-time merge source: sbx rewrites ~/.claude/settings.json at sandbox
# (re)create, so the shim re-merges this snapshot on every launch. As root:
# /usr/local/share/sbx is root-owned.
USER root
RUN install -m 644 /home/agent/.claude/settings.json /usr/local/share/sbx/claude-settings.json
USER agent

# ── Codex ─────────────────────────────────────────────────────────────────────
FROM devstack AS codex
# Bake skills into codex's GLOBAL skills dir (~/.codex/skills). NOT
# ~/.agents/skills: sbx mounts the shared skills store there at create,
# shadowing anything baked. Global instructions live at ~/.codex/AGENTS.md.
COPY --chown=agent:agent build/codex/.agents/skills /home/agent/.codex/skills
COPY --chown=agent:agent config/AGENTS.md /home/agent/.codex/AGENTS.md

# sbx seeds ~/.codex/config.toml unconditionally at sandbox (re)create,
# clobbering anything baked at build time. The sbx manifest launches bare
# `codex` and /home/agent/.local/bin precedes the npm-global bin dir on PATH,
# so a shim there wins without moving the real binary. Assert the real
# binary's location so the build fails loudly if the base image relocates it.
COPY config/gitnexus-mcp-codex.sh /usr/local/share/sbx/gitnexus-mcp-codex.sh
COPY config/codex-settings.sh /usr/local/share/sbx/codex-settings.sh
COPY config/codex-config.toml /usr/local/share/sbx/codex-config.toml
RUN test -x /usr/local/share/npm-global/bin/codex \
    && install -d -o agent -g agent /home/agent/.local /home/agent/.local/bin
COPY --chown=agent:agent --chmod=755 codex-shim.sh /home/agent/.local/bin/codex

USER agent
# Classic builder does not derive HOME from USER; the script below needs it.
ENV HOME=/home/agent

# rtk has no codex integration (`rtk init` only targets Claude Code) — the
# binary ships with prose guidance in AGENTS.md; no hooks.

# Register gitnexus + custom settings at build time too — smoke-tests the
# appenders and covers any launch path that bypasses the shim while
# ~/.codex/config.toml is still the baked one (sbx clobbers it at create; the
# shim re-asserts both at every launch).
RUN sh /usr/local/share/sbx/gitnexus-mcp-codex.sh \
    && sh /usr/local/share/sbx/codex-settings.sh

# ── Cursor (cursor-agent) ─────────────────────────────────────────────────────
FROM devstack AS cursor
# cursor-agent has no global instructions file (it reads AGENTS.md/CLAUDE.md
# at the project root only), so nothing like ~/.claude/CLAUDE.md is baked.
# Skills bake to cursor's global skills dir. Create sandboxes with
# --no-share-skills or sbx mounts its shared store over this path (see README).
COPY --chown=agent:agent build/cursor/.agents/skills /home/agent/.cursor/skills
# Custom settings. sbx's own cli-config seed is onlyIfMissing, so this baked
# file survives sandbox creation — but it MUST keep network.useHttp1ForAgent,
# which sbx would otherwise seed (agent traffic must go through the proxy).
COPY --chown=agent:agent config/cursor-cli-config.json /home/agent/.cursor/cli-config.json

# No shim, unlike claude/codex: sbx's cursor manifest seeds only
# cli-config.json (onlyIfMissing) and never rewrites an MCP config, so the
# baked ~/.cursor/mcp.json survives sandbox creation. The launcher at
# /home/agent/.local/bin/cursor-agent is an auto-update-managed symlink —
# intercepting it would be fragile for no benefit. Assert it exists so the
# build fails loudly if the base image ever relocates it. The merge script
# ships for manual re-assertion (troubleshooting).
COPY config/gitnexus-mcp-cursor.cjs /usr/local/share/sbx/gitnexus-mcp-cursor.cjs
RUN test -x /home/agent/.local/bin/cursor-agent

USER agent
# Classic builder does not derive HOME from USER; rtk/node below need it.
ENV HOME=/home/agent

# Wire RTK's cursor hooks into ~/.cursor/hooks.json. rtk init also writes
# claude-side files (~/.claude/RTK.md) unconditionally and errors if the dir
# is missing — pre-create it; the files are inert in this image.
RUN mkdir -p /home/agent/.claude /home/agent/.cursor \
    && rtk init --global --agent cursor

# Register gitnexus at build time — sbx does not clobber this for cursor.
RUN node /usr/local/share/sbx/gitnexus-mcp-cursor.cjs
