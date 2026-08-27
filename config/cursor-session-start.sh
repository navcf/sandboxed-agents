#!/usr/bin/env sh
# cursor-agent sessionStart hook: the launch step cursor otherwise has no place
# for. cursor's launcher is an auto-update-managed symlink, so unlike claude and
# codex it gets no shim — this hook is the substitute.
#
# Registered by config/cursor-hooks-merge.cjs into ~/.cursor/hooks.json, which
# rtk also writes (it owns `preToolUse`), hence a JSON merge rather than a
# rewrite. Cursor watches that file and reloads it on its own.
#
# Two jobs:
#   1. Fast-forward the skill set, so a new chat always starts current. cursor
#      has NO skills file watcher — the catalog is fixed when a chat starts —
#      so session start is the only moment this can usefully happen.
#   2. Emit `additional_context`, which cursor injects into the agent's context.
#      cursor-agent reads no global instructions file (only AGENTS.md/CLAUDE.md
#      at the project root), so this is the one channel for sandbox-wide
#      guidance, and the only way a cursor agent learns the CLI exists.
#
# Contract: read hook JSON on stdin (ignored here), write hook JSON on stdout.
# Anything on stdout that is not that JSON breaks the hook, so sync's own
# reporting goes to stderr.
set -u

nav-skills sync >&2 2>&1 || echo 'warn: skills sync failed — using the baked snapshot' >&2

# Kept as a single-line literal on purpose: no command output is interpolated,
# so there is nothing to JSON-escape and the hook cannot emit invalid JSON.
cat <<'JSON'
{"additional_context": "Skills are managed by the `nav-skills` CLI, backed by the navcf/nav-skills git repo. `nav-skills list` shows what is installed and how each skill is invoked; `nav-skills sync` fast-forwards from the repo; `nav-skills new <name> <user|model|both>` scaffolds one; `nav-skills doctor` lints them; `nav-skills harvest` packages edits made here as a patch for review on the host. cursor-agent does not reload skills mid-chat, so a skill added after this chat started needs a new chat. Never edit the skills directory directly — the next sync overwrites it; edit the clone at ~/.local/share/nav-skills and harvest. Never commit or push skill changes."}
JSON
