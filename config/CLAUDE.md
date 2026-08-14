# Sandbox Agent Instructions

You are running inside a Docker Sandbox. The workspace is mounted at the same
absolute path as on the host.

## Dev stack — run `devstack up` first

Before installing dependencies, touching Postgres, or running tests in a fresh
workspace, run `devstack up`. It is idempotent and does, in order: start
PostgreSQL 18 (pg_cron is preloaded via a baked drop-in), set the
postgres/postgres password, create the workspace database and point
`cron.database_name` at it, copy `.env.example` → `.env` when `.env` is
missing, `pnpm install` when `node_modules` is absent, migrate, and seed.
`devstack status` shows what is up; `devstack reset` re-bootstraps.

Workspace specifics come from `.local/.devstack.conf` in the repo — `.local/`
is gitignored, so never commit it; `$DEVSTACK_CONF` or a root `.devstack.conf`
also work — (`DB_NAME`,
`MIGRATE_CMD`, `SEED_CMD`, `TOLERATE_MIGRATE_FAIL_IF`, …) — read the header of
`/usr/local/bin/devstack` for the full list. Do not hand-edit
`/etc/postgresql` or hand-roll the database/schema; if a migrate wrapper's
trailing step needs Docker (unavailable in the sandbox), let
`TOLERATE_MIGRATE_FAIL_IF` absorb it instead of working around the project CLI.
The baked Postgres cluster serves TLS with a trusted localhost cert, so
connection strings with `sslmode=require` work as-is.

If date/Intl code ever throws `Invalid string: undefined`, the inherited `TZ`
is not an IANA zone (e.g. macOS "PDT7"). The launcher normally fixes this; if
it leaks through, prefix commands with `TZ=UTC`.

## Tests, screenshots, recordings

Unit/integration tests: use the project's own scripts (`pnpm test`, or the
`TEST_HINT` printed by `devstack up`). Run `devstack up` first — test suites
assume a migrated, seeded database.

E2E / browser work runs HEADLESS ONLY:
- Chromium's headless shell (Playwright 1.58.2) is baked at
  `~/.cache/ms-playwright`. `headless: false` has no binary and will fail —
  do not "fix" this with `playwright install`: browser CDNs are blocked in
  the sandbox. If a project pins a different Playwright version and its
  browser download fails, report the version mismatch to the user instead.
- Screenshots: `page.screenshot({path})` in tests, or
  `npx playwright screenshot <url> <file>` for one-offs. Headless rendering
  is fully capable — screenshots do not need a display.
- Recordings: Playwright's `recordVideo` / `video: 'on'` works headless
  (bundled ffmpeg). There is no apt ffmpeg in the image.
- Save screenshots/videos under the workspace (e.g. `.local/artifacts/`) —
  the workspace is host-mounted, so the user can open them directly.
- `xvfb-run <cmd>` exists for non-browser GUI apps that hard-require a
  display (e.g. Electron).

## RTK — Rust Token Killer

Token-optimized CLI proxy (60-90% savings on dev operations). Hooks are
pre-configured; commands like `git status` are rewritten to `rtk git status`
transparently.

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


## Github

Do not push changes or post comments to Github instead ask for manual review 
before pushing or posting. 

## Comments

Be succinct when writing comments for code and only if the code is not self-
descriptive enough.
