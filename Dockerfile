# Custom Docker Sandboxes template for Claude Code.
# Build via ./build.sh (runs stage.sh first to populate build/.claude/skills
# via the Vercel skills CLI). Everything is baked at build time.

FROM docker/sandbox-templates:claude-code AS rtk
USER root
ENV RTK_INSTALL_DIR=/usr/local/bin
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    # Fail the build here (not at rtk init below) if the installer ignored RTK_INSTALL_DIR.
    && /usr/local/bin/rtk --version

FROM docker/sandbox-templates:claude-code
USER root
COPY --from=rtk /usr/local/bin/rtk /usr/local/bin/rtk

# Sandboxes do NOT sync host ~/.claude — global config and skills must live in the image.
COPY --chown=agent:agent build/.claude/skills /home/agent/.claude/skills
COPY --chown=agent:agent config/CLAUDE.md /home/agent/.claude/CLAUDE.md

# sbx re-seeds ~/.claude.json at sandbox creation, clobbering anything baked at
# build time. Claude is a native install whose launcher symlink lives at
# /home/agent/.local/bin/claude — move it aside and put a shim in its place that
# re-asserts the gitnexus MCP registration just before the real binary launches.
# The mv fails the build loudly if the base image ever relocates the launcher.
COPY config/gitnexus-mcp.cjs /usr/local/share/sbx/gitnexus-mcp.cjs
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
