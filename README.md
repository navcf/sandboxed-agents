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
| `Dockerfile.claude` | Template image on top of `docker/sandbox-templates:claude-code` |
| `Dockerfile.codex` | Template image on top of `docker/sandbox-templates:codex` |
| `Dockerfile.cursor` | Template image on top of `docker/sandbox-templates:cursor-agent` |
| `skills.txt` | Declarative skill sources, one `npx skills add` source per line |
| `stage.sh` | Installs sources into `build/<agent>/` via the [Vercel skills CLI](https://vercel.com/docs/agent-resources/skills) |
| `skills-local/` | Curated local skills, referenced from the manifest |
| `config/CLAUDE.md` | Baked global Claude instructions (RTK + gitnexus usage) |
| `config/AGENTS.md` | Baked global Codex instructions (same content, hook-less RTK) |
| `config/gitnexus-mcp.cjs` | Merges the host MCP entries (gitnexus + agent-bridge) into `~/.claude.json` |
| `config/gitnexus-mcp-codex.sh` | Grep-guard-appends the host MCP entries to `~/.codex/config.toml` |
| `config/gitnexus-mcp-cursor.cjs` | Merges the host MCP entries into `~/.cursor/mcp.json` |
| `claude-shim.sh` | Baked to `/home/agent/.local/bin/claude` (real launcher moved to `claude-real`); re-asserts config sbx clobbers, then `exec`s the real claude |
| `codex-shim.sh` | Baked to `/home/agent/.local/bin/codex` (shadows the npm-global binary via PATH order); same re-assert-then-`exec` pattern |
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
cd /path/to/workspace
sbx run --no-share-skills -t docker.io/navcf/sandbox-templates:claude-code claude
sbx run --no-share-skills -t docker.io/navcf/sandbox-templates:codex codex
sbx run --no-share-skills -t docker.io/navcf/sandbox-templates:cursor-agent cursor
```

Override the image ref with `IMAGE=... ./build.sh claude` (single-agent builds
only).

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
- **`ask_agent` times out after ~1 minute**: that is the *caller's* MCP
  client timeout, not the bridge (which allows 600s). The templates raise it
  — claude via `MCP_TOOL_TIMEOUT=900000` in `config/claude-settings.json`,
  codex via `tool_timeout_sec = 900` on the `agents` server — so a sandbox
  showing this predates the fix: recreate it. Cursor's MCP client timeout is
  not configurable; if cursor-initiated reviews keep timing out, keep review
  prompts narrow (a specific diff, not the whole repo).
- **`ask_agent` fails or hangs**: check the bridge is running on the host
  (`./host-services.sh`) and `localhost:4748` is allowed (`sbx policy
  log`). "no <agent> sandbox found" means the target agent has no sandbox on
  that workspace — create one. A hang usually means the target sandbox is not
  signed in (the headless CLI is waiting on a login prompt); run the agent
  interactively once to authenticate.
- **Stale gitnexus index**: re-run the analyze on the host — never inside the
  sandbox.
