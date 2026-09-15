# syntax=docker/dockerfile:1
# Docker Sandboxes templates for Claude Code and Codex, targeting a single
# project workspace configured at sandbox creation via SBX_WORKSPACE (see
# README). Build via ./build.sh [claude|codex|all], which runs
# `docker build --target <agent> --build-arg BASE_IMAGE=...`.
#
# `artifacts` downloads everything agent-agnostic once (Node, TS toolchain,
# Playwright browsers) and is shared via COPY --link. `common` adds Postgres
# 17 + pg_cron, xvfb, and Chromium's libs, and sets the ENTRYPOINT that starts
# Postgres before any agent CLI runs (config/agent.sh).

# No default on purpose: building without build.sh fails loudly instead of
# silently stacking one agent's config on another's base.
ARG BASE_IMAGE

# ── Shared artifacts — built once, copied into every agent image ─────────────
# Based on the claude-code template so the userland (glibc, os-release)
# matches the images the artifacts land in.
FROM docker/sandbox-templates:claude-code AS artifacts
USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils

COPY config/build-install.sh /tmp/build-install.sh
RUN --mount=type=cache,target=/root/.npm \
    sh /tmp/build-install.sh artifacts

# ── Common — everything both agents share ─────────────────────────────────────
FROM ${BASE_IMAGE} AS common
USER root
COPY --link --from=artifacts /opt/node /opt/node
COPY --link --from=artifacts /opt/node-tools /opt/node-tools
COPY --link --from=artifacts /opt/ms-playwright /opt/ms-playwright

COPY config/build-install.sh /tmp/build-install.sh
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    sh /tmp/build-install.sh postgres && rm /tmp/build-install.sh

COPY config/github-known-hosts /usr/local/share/sbx/github-known-hosts
# Progressive-disclosure companions to CLAUDE.md/AGENTS.md: those stay short
# and point here for task-specific detail.
COPY config/agent-docs/ /usr/local/share/sbx/docs/

# ENTRYPOINT (not a shim) so Postgres is up before ANY agent CLI starts. The
# base images already set ENTRYPOINT ["tini","--"] with CMD as the agent
# binary, so this wraps that same tini rather than disturbing the per-agent
# CMDs below.
COPY --chmod=755 config/agent.sh /usr/local/bin/sbx-agent
ENTRYPOINT ["tini", "--", "/usr/local/bin/sbx-agent", "container-init"]

# sbx forwards the host's TZ, and macOS sends non-IANA abbreviations like
# "PDT7" — ENV loses to a real inherited value, so `sbx-agent` also fixes this
# at runtime; pass `-e TZ=UTC` at sandbox creation too.
ENV TZ=UTC

# ── Claude Code ───────────────────────────────────────────────────────────────
FROM common AS claude
# Sandboxes do NOT sync host ~/.claude — global config must live in the image.
COPY --chown=agent:agent config/CLAUDE.md /home/agent/.claude/CLAUDE.md
COPY --chown=agent:agent config/claude-settings.json /home/agent/.claude/settings.json

# Upgrade claude past whatever the base image baked. CLAUDE_CACHE_BUST (a
# fresh timestamp from build.sh) forces this layer to actually re-run instead
# of being a permanent cache hit.
ARG CLAUDE_CACHE_BUST=0
USER agent
ENV HOME=/home/agent
RUN echo "cache-bust=${CLAUDE_CACHE_BUST}" && curl -fsSL https://claude.ai/install.sh | bash
USER root

# sbx re-seeds ~/.claude.json at sandbox creation, clobbering the baked MCP
# registration — move the native launcher aside and put a shim in its place
# that re-asserts it before every launch.
COPY config/gitnexus-mcp.cjs /usr/local/share/sbx/gitnexus-mcp.cjs
COPY config/claude-settings-merge.cjs /usr/local/share/sbx/claude-settings-merge.cjs
RUN mv /home/agent/.local/bin/claude /home/agent/.local/bin/claude-real
COPY --chown=agent:agent --chmod=755 claude-shim.sh /home/agent/.local/bin/claude

USER agent
ENV HOME=/home/agent
# Covers any launch path that bypasses the shim while ~/.claude.json is still
# the baked one.
RUN node /usr/local/share/sbx/gitnexus-mcp.cjs

# Snapshot for the shim's launch-time merge: sbx rewrites settings.json at
# sandbox (re)create.
USER root
RUN install -m 644 /home/agent/.claude/settings.json /usr/local/share/sbx/claude-settings.json
USER agent

# ── Codex ─────────────────────────────────────────────────────────────────────
FROM common AS codex
COPY --chown=agent:agent config/AGENTS.md /home/agent/.codex/AGENTS.md

# sbx seeds ~/.codex/config.toml unconditionally at sandbox (re)create;
# /home/agent/.local/bin precedes the npm-global bin dir on PATH, so a shim
# there wins without moving the real binary.
COPY config/codex-config.toml /usr/local/share/sbx/codex-config.toml
RUN test -x /usr/local/share/npm-global/bin/codex \
    && install -d -o agent -g agent /home/agent/.local /home/agent/.local/bin
COPY --chown=agent:agent --chmod=755 codex-shim.sh /home/agent/.local/bin/codex

USER agent
ENV HOME=/home/agent

# Upgrade codex past whatever the base image baked. CODEX_CACHE_BUST forces
# this layer to actually re-run, same as CLAUDE_CACHE_BUST above.
ARG CODEX_CACHE_BUST=0
RUN echo "cache-bust=${CODEX_CACHE_BUST}" && npm install -g @openai/codex@latest

# Smoke-tests the appenders and covers any launch path that bypasses the shim
# while config.toml is still the baked one.
RUN sbx-agent gitnexus-codex && sbx-agent codex-settings
