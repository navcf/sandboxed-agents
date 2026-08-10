# Sandbox Agent Instructions

You are running inside a Docker Sandbox. The workspace is mounted at the same
absolute path as on the host.

## RTK — Rust Token Killer

Token-optimized CLI proxy (60-90% savings on dev operations). No hooks are
wired for Codex — prefix high-volume commands yourself: `rtk git status`,
`rtk git diff`, `rtk grep <pattern>`, and so on.

- `rtk gain` — show token savings analytics
- `rtk proxy <cmd>` — execute a raw command without filtering (for debugging)

## GitNexus — Code Intelligence

The `gitnexus` MCP server is pre-configured and connects to a server running on
the **host** (`host.docker.internal:4747`). The code-graph index lives on the
host — do **not** run `gitnexus analyze` or `node .gitnexus/run.cjs` inside the
sandbox; if the index is stale, ask the user to re-analyze on the host.

- Before modifying a function, class, or method, run
  `impact({target: "symbolName", direction: "upstream"})` and report the blast
  radius. Warn the user on HIGH or CRITICAL risk before proceeding.
- Run `detect_changes()` before committing to verify only expected symbols and
  flows are affected.
- Explore unfamiliar code with `query({search_query: "concept"})`; get full
  context on a symbol with `context({name: "symbolName"})`.
- Never rename symbols with find-and-replace — use `rename`.

If the gitnexus MCP server is unreachable, the host server is likely not
running; ask the user to start it (`host-services.sh` on the host) instead of
retrying.

## Peer agents

The `agents` MCP server exposes `ask_agent` — ask another sandboxed agent
(claude, codex, or cursor) to do something, typically review your work. The
peer runs headlessly in its own sandbox on the **same workspace**, so it sees
your uncommitted changes; reference files, diffs, or commits by path in the
prompt and say exactly what to return. Pass your workspace root as `workdir`;
optionally pass `model` (in the peer's own naming) if the user asks for a
specific one. Reviews can take minutes — be patient. Never call `ask_agent`
when the task you are working on was itself given to you via `ask_agent`.

If the tool errors that no sandbox exists for the target agent, relay that to
the user rather than retrying.

## Orgmode

Write all plans in /Users/nav/Documents/Notes in Orgmode format. Do not use markdown, 
txt, or any other format. 
