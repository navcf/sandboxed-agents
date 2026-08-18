# Claude Code + Codex + Cursor sandbox templates

Custom [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) templates with
RTK, the gitnexus MCP server (host-connected), and skills baked in at build
time. No kits, no runtime init — the sandbox is fully configured before the
agent launches. Point multiple agents at the same workspace to have them
review each other's work: the workspace is the same bind-mount in every
sandbox, and the default sandbox names (`claude-<workdir>`, `codex-<workdir>`,
`cursor-<workdir>`) never collide.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | All three template images on top of `docker/sandbox-templates:{claude-code,codex,cursor-agent}` — one target per agent (`claude`/`codex`/`cursor`), sharing an `artifacts` stage (rtk, Node, TS toolchain, Playwright browsers) that downloads once and `COPY --link`s into each image as identical blobs |
| `skills.txt` | Declarative skill sources, one `npx skills add` source per line |
| `stage.sh` | Installs sources into `build/<agent>/` via the [Vercel skills CLI](https://vercel.com/docs/agent-resources/skills) |
| `skills-local/` | Curated local skills, referenced from the manifest |
| `config/CLAUDE.md` | Baked global Claude instructions (RTK + gitnexus usage) |
| `config/AGENTS.md` | Baked global Codex instructions (same content, hook-less RTK) |
| `config/gitnexus-mcp.cjs` | Merges the host MCP entries (gitnexus + agent-bridge) into `~/.claude.json` |
| `config/gitnexus-mcp-codex.sh` | Grep-guard-appends the host MCP entries to `~/.codex/config.toml` |
| `config/gitnexus-mcp-cursor.cjs` | Merges the host MCP entries into `~/.cursor/mcp.json` |
| `config/devstack-install.sh` | Per-agent dev stack install: Postgres 18 + pg_cron, xvfb, Chromium headless-shell deps, plus PATH wiring for the shared artifacts |
| `config/devstack-node.sh` | Artifacts-stage download: official Node build + global pnpm/TypeScript/tsx (`/opt/node`, `/opt/node-tools`) |
| `config/install-browsers.sh` | Artifacts-stage Playwright browser download to `/opt/ms-playwright` (works around the missing arm64 build) |
| `config/devstack` | Baked to `/usr/local/bin/devstack`; project-agnostic lifecycle (start pg, `.env` bootstrap, migrate, seed), configured per workspace via `.local/.devstack.conf` |
| `config/fix-tz.sh` | Sourced by the shims and `devstack`: replaces a non-IANA inherited `TZ` (macOS "PDT7") with UTC |
| `claude-shim.sh` | Baked to `/home/agent/.local/bin/claude` (real launcher moved to `claude-real`); re-asserts config sbx clobbers, fixes TZ, runs `devstack up`, then `exec`s the real claude |
| `codex-shim.sh` | Baked to `/home/agent/.local/bin/codex` (shadows the npm-global binary via PATH order); same re-assert/TZ/devstack-then-`exec` pattern |
| `build.sh` | stage → `docker build` → `docker push`, per agent or all |
| `host-services.sh` | Self-contained host-side MCP servers: gitnexus on :4747 + agent-bridge on :4748 (lets agents ask each other for reviews); stops both together |
| `build/<agent>/` | Generated build contexts (never edit; recreated by `stage.sh`) |

## Workflow

```sh
./build.sh          # stage skills, build, push all images (or ./build.sh claude|codex|cursor)
./host-services.sh  # on the host, in a separate terminal — gitnexus MCP on :4747
                    # + agent-to-agent bridge on :4748

# One-time: the sandbox proxy translates host.docker.internal to the host's
# localhost and default-denies it — allow the two host MCP ports:
sbx policy allow network "localhost:4747"
sbx policy allow network "localhost:4748"

# One-time, only if the workload inside the sandbox needs them at RUNTIME.
# Nothing the images download at BUILD time needs a policy entry: ./build.sh
# runs `docker build` on the host, outside the sbx proxy. That covers
# nodejs.org, the npm registry, the Ubuntu archive and the Playwright binaries.
#
# Playwright — only needed if an agent re-runs `playwright install` inside a
# sandbox (version drift from the baked browsers). All three are default-denied:
sbx policy allow network "cdn.playwright.dev,playwright.download.prss.microsoft.com,storage.googleapis.com"
# Stripe — needed by anything that mounts Stripe Elements in a browser, e.g. a
# checkout page whose pay button gates on the PaymentElement reporting
# completeness. Drop this line if you never drive a payment UI in a sandbox:
sbx policy allow network "js.stripe.com,api.stripe.com,m.stripe.network,r.stripe.com,hooks.stripe.com"
#
# Already reachable by default, listed so nobody re-diagnoses them:
#   registry.npmjs.org, archive.ubuntu.com, nodejs.org, dl.google.com,
#   github.com, raw.githubusercontent.com
# Diagnose any block with `sbx policy log`.

# One-time per service: agent logins. Credentials are proxy-managed by sbx;
# nothing is baked into the images. (anthropic is likely already set up.)
sbx secret set -g openai --oauth   # ChatGPT login for codex
# Cursor OAuth cannot be started from `sbx secret set` — sign in from INSIDE
# the first cursor sandbox (run `sbx run ... cursor`, then complete the
# sign-in it prompts for; or run an API key in with `sbx secret set -g cursor`).
# The proxy captures the login and reuses it for every later cursor sandbox.

# First run creates the sandbox (from the workspace dir; flags only matter at
# creation). --no-share-skills is REQUIRED for baked skills to be visible —
# see "How it works". Thereafter a bare `sbx run claude` / `sbx run codex` /
# `sbx run cursor` re-attaches via the default sandbox name (<agent>-<workdir>).
# `-e TZ=UTC`: the claude/codex shims and devstack replace a non-IANA inherited
# TZ with UTC on their own, but cursor's launcher is not shimmed — keep the
# flag, especially for cursor. See "Dev stack" below.
cd /path/to/workspace
sbx create --clone --no-share-skills --name claude-<issue-id> -e TZ=UTC -t docker.io/navcf/sandbox-templates:claude-code claude . [dir-to-mount]
sbx create --clone --no-share-skills --name claude-<issue-id> -e TZ=UTC -t docker.io/navcf/sandbox-templates:codex codex . [dir-to-mount]
sbx create --clone --no-share-skills --name claude-<issue-id> -e TZ=UTC -t docker.io/navcf/sandbox-templates:cursor-agent cursor . [dir-to-mount]

```

Override the image ref with `IMAGE=... ./build.sh claude` (single-agent builds
only).

## Dev stack

The images bake enough to bring a typical Node + Postgres monorepo up inside a
sandbox — a seeded database, unit/integration/E2E tests, and a real browser for
screenshots and video.

```sh
devstack up        # start pg, bootstrap the db, .env from .env.example,
                   # install deps; migrate+seed only if the db is still empty
devstack status
devstack reset     # explicit rebuild: re-bootstrap, migrate, reseed
devstack down
```

With no config file, `up` infers the database name from the workspace's
`.env`/`.env.example` (`DATABASE_NAME`, `POSTGRES_DB`, `PGDATABASE`, or the
`DATABASE_URL` path) and warns that nothing was migrated or seeded. `up` never
touches a database that already has tables — `MIGRATE_CMD` is commonly a full
rebuild (`db reset`), so only the explicit `devstack reset` re-runs it.

The claude/codex shims run `devstack up` automatically at every launch (a ~1s
no-op once bootstrapped; it also restarts Postgres after a sandbox
stop/resume), so first boot needs no manual bootstrapping and the baked global
instructions (`config/CLAUDE.md` / `config/AGENTS.md`) tell agents to verify
rather than bootstrap. cursor has no shim — run `devstack up` in the sandbox
yourself, or let the project's `AGENTS.md` instruct the agent to.

`devstack` itself is project-agnostic. Anything workspace-specific comes from an
optional config file, resolved in order: `$DEVSTACK_CONF` (explicit path),
`.local/.devstack.conf` (preferred — `.local/` is typically gitignored, so the
config never dirties the workspace's `git status`), then a legacy
`.devstack.conf` at the workspace root:

```sh
DB_NAME=myapp                       # database to create; also gets pg_cron
INIT_SQL=db/init.sql                # optional, relative to the workspace root
MIGRATE_CMD='pnpm db migrate'       # optional
SEED_CMD='pnpm seed'                # optional; $SEED_PRESET is exported to it
TEST_HINT='pnpm test'               # optional, printed when `up` finishes
TOLERATE_MIGRATE_FAIL_IF='Migrations succeeded'
    # optional: treat a non-zero MIGRATE_CMD as success when its output contains
    # this string — for CLIs whose migrate wrapper ends in a step that cannot run
    # in a sandbox (codegen shelling out to `docker exec`, say) after the
    # migrations themselves have already applied.
```

Two behaviours worth knowing:

- **No Docker-in-Docker.** Dev CLIs commonly probe for a local `psql` /
  `pg_isready` and only fall back to `docker compose up` when nothing is
  listening, so a native cluster satisfies them with far less machinery.
- **`migrate` cleans up after itself.** If `MIGRATE_CMD` regenerates checked-in
  files as a side effect, `devstack` reverts exactly the files that run dirtied,
  and only those that were clean beforehand — work in progress is never touched.

Four things the stock base image gets wrong, each fixed in
`config/devstack-install.sh` (worth knowing because the symptoms point nowhere
near the cause):

1. **Node has no TypeScript support.** `/usr/bin/node` is Ubuntu's package,
   built without amaro — `node --experimental-strip-types x.ts` gives
   `ERR_NO_TYPESCRIPT`. Anything invoking `node some.ts` directly breaks in
   confusing ways: task runners report a project-graph error and every package
   logs `failed to load config from …/vitest.config.ts`, i.e. no tests run at
   all. An official nodejs.org build goes to `/opt/node`, ahead of `/usr/bin` on
   PATH. See "TypeScript" below for what that does and doesn't buy.
2. **`TZ` arrives as an invalid zone.** sbx forwards the host's `TZ`, and macOS
   sends abbreviations — `TZ="PDT7"`. `Intl.DateTimeFormat().resolvedOptions()
   .timeZone` then returns `undefined` and every temporal-polyfill entry point
   throws `TypeError: Invalid string: undefined`. `ENV TZ=UTC` in the Dockerfile
   loses to a real inherited value, which is why `sbx run` needs `-e TZ=UTC`.
3. **Postgres TLS.** `sslmode=require` in a connection string is verified end to
   end by node-postgres, so Ubuntu's snakeoil cert (named for the container)
   gives `ERR_TLS_CERT_ALTNAME_INVALID` and any untrusted self-signed cert gives
   `DEPTH_ZERO_SELF_SIGNED_CERT`. The image issues a `CN=localhost` cert and
   trusts it, keeping the connection verified rather than downgrading to
   `sslmode=disable`.
4. **Playwright has no `ubuntu26.04-arm64` build** and refuses before
   downloading. Ubuntu's `chromium` is a snap stub and Chrome has no Linux/arm64
   build, so `config/install-browsers.sh` presents 24.04 in `/etc/os-release`
   for the duration of the install; the noble arm64 binaries run fine on 26.04's
   newer glibc.

### TypeScript

Three layers, because Node's built-in support is narrower than it looks:

| | Runs `.ts` | Non-erasable syntax (`enum`, parameter properties) | Type-checks |
|---|---|---|---|
| `node x.ts` | yes | **no** — `SyntaxError` | **no** |
| `node --experimental-transform-types x.ts` | yes | yes | no |
| `tsx x.ts` | yes | yes | no |
| `tsc` | compiles | yes | **yes** |

Node *strips* types: it erases annotations and executes, so
`const n: number = "nope"` runs without complaint. Fine for the direct
`node foo.ts` invocations tooling makes, but it is not a compiler.

So `typescript` and `tsx` are installed globally too. These are a **fallback**:
inside an installed workspace, `pnpm exec tsc` and `npx tsc` resolve
`node_modules/.bin` first, so a project's own pinned compiler always wins. The
globals exist for scratch `.ts` files, a repo before its install has run, and
one-off scripts outside any workspace.

Postgres is **18**, from Ubuntu 26.04's main archive — no third-party repo, and
`postgresql-18-cron` is packaged for arm64 as well as amd64. Pinning 17 would
mean adding PGDG *and* compiling pg_cron from source on Apple Silicon, since
PGDG builds `postgresql-17-cron` for amd64 only.

If a project's CI pins a different major, note that `pg_dump` output is not
identical across majors — Postgres 18 emits named NOT NULL constraints where 17
does not, for instance. Don't commit schema dumps generated in a sandbox.
## Skills

Skills are managed with the [Vercel skills CLI](https://vercel.com/docs/agent-resources/skills).
Each non-comment line in `skills.txt` is passed to
`npx skills add <line> -a <agent> -y --copy` (`claude-code`, `codex`, or
`cursor`), so any source format the CLI accepts works:

- `owner/repo` or full GitHub/GitLab/git URLs; pin with
  `https://github.com/<owner>/<repo>/tree/<sha>`.
- `-s <name>` selects skills from multi-skill repos (`-s '*'` for all).
- Local paths — `./` and `../` resolve relative to this directory; `~` expands
  to your home.

`npx skills find <query>` discovers new skills; later entries override earlier
ones on name collision. Inside the sandbox the agent can also run
`npx skills add` itself to install more.

**Shared-skills shadowing**: unless a sandbox is created with
`--no-share-skills`, sbx mounts its (host-side, initially empty) shared skills
store over `~/.claude/skills`, `~/.agents/skills`, and `~/.cursor/skills`
inside the container — hiding every skill baked at those paths. Always create
sandboxes from these templates with `--no-share-skills`. (The codex image
bakes to `~/.codex/skills`, which is not a mount target, but use the flag
everywhere for consistency.)

## Stopping and resuming

Exiting an agent's TUI leaves its sandbox running in the background;
`sbx stop <sandbox>` shuts it down cleanly. Stopped sandboxes retain all
state and restart automatically on the next `sbx run`. A computer restart
just stops them the same way — nothing is lost.

After a reboot: start Docker Desktop, run `./host-services.sh`, then
re-attach from the workspace dir. Each agent resumes its previous
conversation with its own flag, passed after `--`:

```sh
sbx run claude -- --continue     # resume the last claude conversation
sbx run codex -- resume --last   # resume the last codex session (or `resume` for a picker)
sbx run cursor -- --resume       # pick a cursor chat (or `-- --continue` for the latest)
```

`sbx rm` is what actually discards state: the container filesystem — and
with it codex/cursor session history — is gone. Claude's conversation
history lives on sbx-managed persistent volumes (`~/.claude/projects` etc.)
and survives even removal/recreation.

## Agent-to-agent review

Agents cannot run each other's CLIs inside their own sandbox: sbx injects
credentials and allows API domains per agent manifest, so e.g. `codex` inside
the claude sandbox has no OpenAI key and no route to `api.openai.com`.
Instead, `host-services.sh` serves an MCP server (`agents`, registered in
all three templates) with one tool:

- `ask_agent({agent, prompt, workdir})` — runs the target agent **headlessly
  inside its own sandbox** via `sbx exec` (`claude -p` / `codex exec` /
  `cursor-agent -p`), against the same shared workspace, and returns its
  final answer. `workdir` is the absolute workspace path, used to find the
  peer's sandbox (falls back to the default `<agent>-<workdir>` name; pass
  `sandbox` to override).

So with claude and codex sandboxes on the same workspace, you can tell
claude: *"implement X, then ask codex to review your diff"* — claude calls
`ask_agent(agent: "codex", prompt: "Review the uncommitted changes…",
workdir: "<workspace>")` and gets the review back as text. The peer sees
uncommitted changes (same bind-mount). Requirements: the bridge running on
the host, the `localhost:4748` policy allow, and a signed-in sandbox for the
target agent. The instruction files tell agents not to chain `ask_agent`
calls (no review-of-review loops).

## How it works

- Sandboxes do **not** sync host `~/.claude`; the claude image bakes
  `~/.claude/skills`, `~/.claude/CLAUDE.md`, RTK hooks (`rtk init --global
  --auto-patch`), and the gitnexus MCP registration in `~/.claude.json`.
- sbx **re-seeds `~/.claude.json` at sandbox creation**, clobbering the baked
  MCP registration. The Dockerfile moves the native-install launcher symlink
  (`/home/agent/.local/bin/claude`) to `claude-real` and puts a shim in its
  place that re-asserts the registration via `config/gitnexus-mcp.cjs` on every
  launch, then `exec`s `claude-real`. (Auto-updates would rewrite the launcher
  path over the shim; sbx seeds `autoUpdates: false`, so this holds.)
- The codex image uses the same shim trick with less ceremony: sbx seeds
  `~/.codex/config.toml` unconditionally at sandbox (re)create, so
  `codex-shim.sh` — at `/home/agent/.local/bin/codex`, which precedes the real
  npm-global binary on PATH, no `mv` needed — appends the gitnexus block via
  `config/gitnexus-mcp-codex.sh` (grep-guarded, never a rewrite) before
  `exec`ing the real codex. Skills bake to `~/.codex/skills` (codex's global
  skills dir, and not a shared-store mount target). Global instructions live
  at `~/.codex/AGENTS.md`. RTK has no codex integration, so the binary ships
  hook-less with usage guidance in `AGENTS.md`.
- The cursor image needs **no shim**: sbx's cursor manifest seeds only
  `~/.cursor/cli-config.json` (and only if missing) and never rewrites an MCP
  config, so the baked `~/.cursor/mcp.json` survives creation (verified).
  RTK hooks are wired via `rtk init --global --agent cursor`
  (`~/.cursor/hooks.json`, `preToolUse` → `rtk hook cursor`). Skills bake to
  `~/.cursor/skills` (needs `--no-share-skills`, see above). cursor-agent has
  no global instructions file — it reads `AGENTS.md`/`CLAUDE.md` at the
  project root only, so put sandbox guidance in the workspace if you want
  cursor to see it. Auth is injected per-run as `CURSOR_AUTH_TOKEN` by sbx
  (`AGENT_CLI_CREDENTIAL_STORE=memory`); sbx also pre-trusts the workspace so
  the TUI skips its trust prompt.
- The workspace mounts at the same absolute path as on the host — never bake
  files under a workspace path (the mount would shadow them).
- Nothing in the sandbox depends on this directory: `.local/` is gitignored
  (absent in `sbx create --clone` sandboxes), but `skills-local/` and
  `skills.txt` are only read at image build time on the host. Gitignored skills
  you want inside the sandbox must go through the image bake, not the
  workspace; committed project skills (`.ai/skills`) come with the workspace
  in both modes.
- gitnexus itself never runs in the sandbox; MCP traffic goes to the host via
  `http://host.docker.internal:4747/mcp`.

## Troubleshooting

- **gitnexus MCP unreachable from the sandbox (proxy 403)**: all sandbox
  traffic goes through the host-side proxy, which rewrites
  `host.docker.internal` to `localhost` and default-denies it. Requires the
  one-time `sbx policy allow network "localhost:4747"`; diagnose with
  `sbx policy log` (look for blocked `localhost:4747`). The proxy connects to
  the host's loopback, so the server's default `127.0.0.1` bind is correct.
- **gitnexus missing from `claude mcp list`**: `~/.claude.json` was re-seeded
  by sbx and the shim didn't run — check that
  `/home/agent/.local/bin/claude` is the shim script (and `claude-real` exists
  beside it), and re-assert manually with
  `node /usr/local/share/sbx/gitnexus-mcp.cjs`.
- **gitnexus missing from codex's MCP servers**: `~/.codex/config.toml` was
  re-seeded and the shim didn't run — check that
  `/home/agent/.local/bin/codex` is the shim script, and re-assert manually
  with `sh /usr/local/share/sbx/gitnexus-mcp-codex.sh`.
- **gitnexus missing from cursor's MCP servers**: re-assert manually with
  `node /usr/local/share/sbx/gitnexus-mcp-cursor.cjs` (and report it — sbx is
  not expected to touch `~/.cursor/mcp.json`).
- **Baked skills missing inside a sandbox** (`ls ~/.claude/skills` or
  `~/.cursor/skills` is empty): the sandbox was created without
  `--no-share-skills`, so sbx mounted its empty shared store over the baked
  dir. Recreate the sandbox with the flag.
- **codex not signed in**: run `sbx secret set -g openai --oauth` on the host,
  then recreate the sandbox.
- **cursor not signed in**: cursor OAuth cannot be started from
  `sbx secret set` — sign in from inside the cursor sandbox itself (the TUI
  prompts on first run); the proxy captures it globally. Alternatively store
  an API key with `sbx secret set -g cursor`.
- **`ask_agent` times out**: everything is capped at **1 hour**, in three
  independent places that must agree — the bridge default
  (`timeoutMs` in `host-services.sh`, overridable per call via
  `timeout_seconds`), claude's `MCP_TOOL_TIMEOUT=3600000` in
  `config/claude-settings.json`, and codex's `tool_timeout_sec = 3600` on the
  `agents` server in `config/gitnexus-mcp-codex.sh`. The *lowest* of these wins,
  and the caller's client timeout is usually it: a review dying at ~15 minutes
  despite `timeout_seconds: 3600` means the sandbox still has the old
  `MCP_TOOL_TIMEOUT=900000` baked in — recreate it. Cursor's MCP client timeout
  is not configurable; if cursor-initiated reviews keep timing out, split the
  work into narrower prompts (one subsystem or one diff per call) rather than
  raising anything.
- **`ask_agent` fails or hangs**: check the bridge is running on the host
  (`./host-services.sh`) and `localhost:4748` is allowed (`sbx policy
  log`). "no <agent> sandbox found" means the target agent has no sandbox on
  that workspace — create one. A hang usually means the target sandbox is not
  signed in (the headless CLI is waiting on a login prompt); run the agent
  interactively once to authenticate.
- **Stale gitnexus index**: re-run the analyze on the host — never inside the
  sandbox.
