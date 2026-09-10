# syntax=docker/dockerfile:1
# Custom Docker Sandboxes templates for Claude Code, Codex, and Cursor.
# Build via ./build.sh [claude|codex|cursor|all] — it runs
#   docker build --target <agent> --build-arg BASE_IMAGE=docker/sandbox-templates:<tag>
# Config is baked at build time; skills are not. Skills are committed content in
# navcf/nav-skills (private), baked here as an offline floor from a named build
# context and fast-forwarded by the agent shims at every launch — see
# config/nav-skills and the README.
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
# Skill delivery for all three agents. Skills are committed content in
# navcf/nav-skills, not build output: each agent stage below bakes a checkout as
# an offline floor, and the shims fast-forward it at every launch, so changing a
# skill needs a push rather than an image rebuild.
COPY --chmod=755 config/nav-skills /usr/local/bin/nav-skills
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
# Sandboxes do NOT sync host ~/.claude — global config must live in the image.
COPY --chown=agent:agent config/CLAUDE.md /home/agent/.claude/CLAUDE.md
# Custom settings baked before rtk init patches its hooks into the same file.
COPY --chown=agent:agent config/claude-settings.json /home/agent/.claude/settings.json

# Bake the skill-set floor from the `nav-skills` named build context (build.sh
# passes --build-context nav-skills=<checkout>). NOT a clone: the repo is
# private, and a credential must never end up in a layer. Copying the checkout
# whole brings its .git along, so the result is a real clone whose origin is the
# SSH remote — exactly what the launch-time `nav-skills sync` fetches from.
# Copied root-owned on purpose: these RUN steps are root, and git refuses to
# operate on a repo owned by a different user. The chown below hands it over.
#
# A stale floor is harmless: every launch fast-forwards it.
COPY --from=nav-skills . /home/agent/.local/share/nav-skills
# Materializing into ~/.claude/skills also brings in the nav-skills management
# plugin, which auto-loads as nav-skills@skills-dir — no marketplace, no install.
RUN NAV_SKILLS_HOME=/home/agent/.local/share/nav-skills \
    NAV_SKILLS_DIR=/home/agent/.claude/skills \
    nav-skills materialize \
 && chown -R agent:agent /home/agent/.claude /home/agent/.local/share/nav-skills

# Upgrade claude past whatever version the base image baked, via the same
# native installer the base image itself used. Writes a new
# ~/.local/share/claude/versions/<x> and re-points the ~/.local/bin/claude
# symlink at it, so the mv/shim below still finds it at the expected path.
# CLAUDE_CACHE_BUST (build.sh passes a fresh timestamp every build) is
# referenced in the RUN below so this layer — pure cache-hit forever
# otherwise, since the command text never changes even though the remote
# installer's output does — actually re-runs and picks up new releases.
ARG CLAUDE_CACHE_BUST=0
USER agent
ENV HOME=/home/agent
RUN echo "cache-bust=${CLAUDE_CACHE_BUST}" && curl -fsSL https://claude.ai/install.sh | bash
USER root

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
COPY --chown=agent:agent config/AGENTS.md /home/agent/.codex/AGENTS.md

# Skills go to codex's GLOBAL skills dir (~/.codex/skills). NOT ~/.agents/skills:
# sbx mounts the shared skills store there at create, shadowing anything baked.
# Codex also ships its own built-ins into ~/.codex/skills/.system — nav-skills
# only ever touches the entries the repo tracks, so those survive every sync.
#
# Codex ignores `disable-model-invocation`; its equivalent is
# agents/openai.yaml → policy.allow_implicit_invocation, which the skills repo
# sets alongside it. See `nav-skills doctor`.
# Bake the skill-set floor from the `nav-skills` named build context (build.sh
# passes --build-context nav-skills=<checkout>). NOT a clone: the repo is
# private, and a credential must never end up in a layer. Copying the checkout
# whole brings its .git along, so the result is a real clone whose origin is the
# SSH remote — exactly what the launch-time `nav-skills sync` fetches from.
# Copied root-owned on purpose: these RUN steps are root, and git refuses to
# operate on a repo owned by a different user. The chown below hands it over.
#
# A stale floor is harmless: every launch fast-forwards it.
COPY --from=nav-skills . /home/agent/.local/share/nav-skills
RUN NAV_SKILLS_HOME=/home/agent/.local/share/nav-skills \
    NAV_SKILLS_DIR=/home/agent/.codex/skills \
    nav-skills materialize \
 && chown -R agent:agent /home/agent/.codex /home/agent/.local/share/nav-skills

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

# Upgrade codex past whatever version the base image baked — same npm-global
# prefix the base image installed into (already on PATH), so the symlink at
# /usr/local/share/npm-global/bin/codex that the shim execs stays valid.
# CODEX_CACHE_BUST (build.sh passes a fresh timestamp every build) is
# referenced in the RUN below for the same reason as CLAUDE_CACHE_BUST above:
# otherwise this layer is a permanent cache hit and never re-checks npm.
ARG CODEX_CACHE_BUST=0
RUN echo "cache-bust=${CODEX_CACHE_BUST}" && npm install -g @openai/codex@latest

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
# at the project root only), so nothing like ~/.claude/CLAUDE.md is baked — the
# sessionStart hook's additional_context is the substitute (see below).
#
# ~/.cursor/skills is the path the CLI loads most reliably (~/.agents/skills has
# known CLI parity gaps). Cursor's own built-ins live in ~/.cursor/skills-cursor,
# a different directory, so nav-skills never touches them. Create sandboxes with
# --no-share-skills or sbx mounts its shared store over this path (see README).
# Bake the skill-set floor from the `nav-skills` named build context (build.sh
# passes --build-context nav-skills=<checkout>). NOT a clone: the repo is
# private, and a credential must never end up in a layer. Copying the checkout
# whole brings its .git along, so the result is a real clone whose origin is the
# SSH remote — exactly what the launch-time `nav-skills sync` fetches from.
# Copied root-owned on purpose: these RUN steps are root, and git refuses to
# operate on a repo owned by a different user. The chown below hands it over.
#
# A stale floor is harmless: every launch fast-forwards it.
COPY --from=nav-skills . /home/agent/.local/share/nav-skills
RUN NAV_SKILLS_HOME=/home/agent/.local/share/nav-skills \
    NAV_SKILLS_DIR=/home/agent/.cursor/skills \
    nav-skills materialize \
 && chown -R agent:agent /home/agent/.cursor /home/agent/.local/share/nav-skills
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
# ...with one exception: a sessionStart hook stands in for the missing shim,
# syncing skills and injecting the sandbox guidance cursor has no global
# instructions file to hold. See config/cursor-session-start.sh.
COPY --chmod=755 config/cursor-session-start.sh /usr/local/share/sbx/cursor-session-start.sh
COPY config/cursor-hooks-merge.cjs /usr/local/share/sbx/cursor-hooks-merge.cjs
RUN test -x /home/agent/.local/bin/cursor-agent

USER agent
# Classic builder does not derive HOME from USER; rtk/node below need it.
ENV HOME=/home/agent

# Wire RTK's cursor hooks into ~/.cursor/hooks.json. rtk init also writes
# claude-side files (~/.claude/RTK.md) unconditionally and errors if the dir
# is missing — pre-create it; the files are inert in this image.
RUN mkdir -p /home/agent/.claude /home/agent/.cursor \
    && rtk init --global --agent cursor
# Add the sessionStart hook AFTER rtk, which owns preToolUse in the same file
# and rewrites it. Merge, never overwrite.
RUN node /usr/local/share/sbx/cursor-hooks-merge.cjs

# Register gitnexus at build time — sbx does not clobber this for cursor.
RUN node /usr/local/share/sbx/gitnexus-mcp-cursor.cjs
