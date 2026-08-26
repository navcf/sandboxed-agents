# Sandbox Agent Instructions

You are in a Docker Sandbox: an Ubuntu container with the project workspace
mounted at the same absolute path as on the host. The image bakes a full
Node + Postgres dev stack; there is no Docker daemon, no display, and browser
CDNs are blocked. Task-specific guides live in `/usr/local/share/sbx/docs/` —
read the relevant one BEFORE working around an environment limitation.

## Environment

- The workspace was bootstrapped at launch by `devstack up` (Postgres 18 on
  localhost:5432, `.env`, dependencies; migrate+seed only if the DB was
  empty). If it warned or failed, fix that before installing anything or
  running tests: `devstack status`, then `devstack up`. `devstack reset`
  wipes and rebuilds the database — only use it deliberately.
  Details (config keys, TLS, TZ gotcha): docs/devstack.md
- Never install docker or run `docker compose` — when project tooling shells
  out to Docker, route around it: docs/no-docker.md
- Browser work is headless-only. Use the baked `playwright` CLI, never bare
  `npx playwright` (resolves a mismatched version), and never run
  `playwright install` (the download is blocked — report a pinned-version
  mismatch to the user instead). Tests, screenshots, recordings: docs/testing.md
- Put artifacts the user should open (screenshots, videos, reports) under the
  workspace, e.g. `.local/artifacts/`.

## RTK — token-optimized CLI proxy

No hooks are wired for Codex — prefix high-volume commands yourself:
`rtk git status`, `rtk git diff`, `rtk grep <pattern>`, and so on.
`rtk proxy <cmd>` runs a command unfiltered (debugging); `rtk gain` shows
savings.

## GitNexus — code intelligence (MCP)

The `gitnexus` MCP server connects to the HOST (host.docker.internal:4747)
and the code-graph index lives there. Never run `gitnexus analyze` in the
sandbox; if the index is stale or the server unreachable, ask the user to fix
it on the host (`host-services.sh`) instead of retrying.

- Before modifying a function/class/method:
  `impact({target: "symbolName", direction: "upstream"})` — report the blast
  radius, and warn the user on HIGH or CRITICAL risk before proceeding.
- Before committing: `detect_changes()` to confirm only expected symbols and
  flows are affected.
- Explore unfamiliar code with `query({search_query: "concept"})`; get a
  symbol's callers/callees with `context({name: "symbolName"})`.
- Rename symbols with `rename`, never find-and-replace.

## Peer agents (MCP)

`ask_agent({agent, prompt, workdir})` runs another sandboxed agent (claude,
codex, or cursor) headlessly on the same workspace — it sees your uncommitted
changes. Say exactly what it should return; pass your workspace root as
`workdir`. A slow peer returns a job id — poll `get_agent_response({job_id})`
until the real answer arrives (long reviews can take 30-60 min).

- Never re-issue `ask_agent` for a task you already submitted; a "still
  running" status line is not the answer — keep polling.
- Never call `ask_agent` when your own task arrived via `ask_agent`.
- "No sandbox exists" for the target agent → relay to the user, don't retry.

## Clone-mode git

If `/run/sandbox/source` exists, you work on a private clone: the user sees
only your COMMITS. Work on a branch and commit early and often.

- Pick up the user's commits with `git fetch host && git rebase host/<branch>`
  (`host` is the live read-only mount of the host repo; it also lets you
  browse the user's uncommitted files at `/run/sandbox/source`).
- Never push to `host` — the user pulls your commits from their side.

## Conventions

- Write all plans in /Users/nav/Documents/Notes in Orgmode format — never
  markdown or txt.
- Never push changes or post comments to GitHub — prepare the content and ask
  for review first. If git-over-SSH fails (`Permission denied (publickey)` or
  a hang), no key was mounted: report it; never generate keys, edit `~/.ssh`,
  or rewrite remotes.
- Write code comments only where the code is not self-descriptive, and keep
  them succinct.
