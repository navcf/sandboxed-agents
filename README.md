# Claude Code + Codex sandbox templates

Custom [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) templates,
targeting a single project workspace you configure (`SBX_WORKSPACE`, see
below), with the gitnexus MCP server (host-connected) baked in and
PostgreSQL 17 (pg_cron, extensions, schema — matching the project's own
`postgres/Dockerfile`/`postgres/init-db.sql`) started and migrated before any
agent CLI launches. No kits; config is fully in place before the agent
launches. Point both agents at the same workspace to have them review each
other's work: the workspace is the same bind-mount in every sandbox, and the
default sandbox names (`claude-<workdir>`, `codex-<workdir>`) never collide.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Both template images on top of `docker/sandbox-templates:{claude-code,codex}` — one target per agent (`claude`/`codex`), sharing an `artifacts` stage (Node, TS toolchain, Playwright browsers) that downloads once and `COPY --link`s into each image as identical blobs |
| `config/CLAUDE.md` | Baked global Claude instructions — short, universal rules only; task detail lives in `config/agent-docs/` |
| `config/AGENTS.md` | Baked global Codex instructions (same content) |
| `config/agent-docs/` | Baked to `/usr/local/share/sbx/docs/`: progressive-disclosure companions the instruction files point at (database, Docker route-arounds, testing/screenshots) |
| `config/gitnexus-mcp.cjs` | Merges the host MCP entries (gitnexus + agent-bridge) into `~/.claude.json` |
| `config/build-install.sh` | Build-time install, run from the Dockerfile: `artifacts` (Node, TS toolchain, Playwright browsers) and `postgres` (PostgreSQL 17 + pg_cron built from source, xvfb, Chromium libs) |
| `config/agent.sh` | Baked to `/usr/local/bin/sbx-agent` — every runtime step as one subcommand: `container-init` (the image `ENTRYPOINT`), `launch <claude\|codex>` (what the shims delegate to), plus `setup-ssh`/`codex-settings`/`gitnexus-codex` |
| `config/github-known-hosts` | GitHub's published SSH host keys (from `api.github.com/meta`), baked so the first git-over-SSH operation never hangs on a host-key prompt |
| `claude-shim.sh` | Baked to `/home/agent/.local/bin/claude` (real launcher moved to `claude-real`); delegates to `sbx-agent launch claude` |
| `codex-shim.sh` | Baked to `/home/agent/.local/bin/codex` (shadows the npm-global binary via PATH order); delegates to `sbx-agent launch codex` |
| `build.sh` | `docker build` → `docker push`, per agent or all |
| `host-services.sh` | Self-contained host-side agent-bridge MCP server on :4748 (lets agents ask each other for reviews) |
| `sbx-agents` | Host-side CLI, configured via `SBX_WORKSPACE`/`SBX_GH_REPO` env vars (hardcoded to one repo per environment): `issue` (launch/re-attach with a GitHub issue/PR preloaded), `ls`/`pull`/`push`/`harvest`/`clean` (sync `--clone` sandbox branches into worktrees), `rm` (destroy a sandbox + its worktree/branch) — see "Clone mode: syncing work" |

## Workflow

Set these once, e.g. in your shell profile:

```sh
export SBX_WORKSPACE=$HOME/Projects/myrepo       # your project's absolute path
export SBX_TEMPLATE_IMAGE=docker.io/you/sandbox-templates  # where build.sh pushes
```

```sh
SBX_TEMPLATE_IMAGE=$SBX_TEMPLATE_IMAGE ./build.sh   # build and push all images (or ./build.sh claude|codex)
./host-services.sh  # on the host, in a separate terminal — agent-to-agent bridge on :4748
(cd "$SBX_WORKSPACE" && docker compose --profile gitnexus up -d gitnexus)  # gitnexus MCP on :4747

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

# First run creates the sandbox (from $SBX_WORKSPACE; flags only matter at
# creation). Thereafter a bare `sbx run claude` / `sbx run codex` re-attaches
# via the default sandbox name (<agent>-<workdir>).
# `-e TZ=UTC`: `sbx-agent` replaces a non-IANA inherited TZ with UTC on its
# own, but keep the flag for belt-and-suspenders. See "Dev stack" below.
# `-e SBX_WORKSPACE=...`: tells the in-container sbx-agent (config/agent.sh)
# the workspace's absolute path, since it can't otherwise discover it.
cd "$SBX_WORKSPACE"
sbx create --clone --name claude-<issue-id> -e TZ=UTC -e SBX_WORKSPACE="$SBX_WORKSPACE" -t "$SBX_TEMPLATE_IMAGE:claude-code" claude .
sbx create --clone --name claude-<issue-id> -e TZ=UTC -e SBX_WORKSPACE="$SBX_WORKSPACE" -t "$SBX_TEMPLATE_IMAGE:codex" codex .

```

Override the image ref with `IMAGE=... ./build.sh claude` (single-agent builds
only) instead of `SBX_TEMPLATE_IMAGE`.

## Clone mode: syncing work

With `--clone` the agent works on a private clone of your repo, not on your
working tree. sbx already provides the plumbing in both directions:

- **Host → sandbox**: your repo is mounted **live and read-only** inside the
  sandbox at `/run/sandbox/source` (the clone borrows its objects via git
  alternates). The claude/codex shims register it as the `host` remote in the
  clone — the agent pulls your commits, including ones made after the sandbox
  was created, with `git fetch host` (and the shims drop the useless
  `sandbox-*` remotes the clone copies from your host config).
- **Sandbox → host**: each running clone sandbox serves a git daemon on a
  published loopback port, and sbx maintains a `sandbox-<name>` remote in your
  repo pointing at it (removed on stop, re-added by `sbx run`). The daemon has
  no receive-pack, so nothing can be pushed *into* a sandbox — and only
  **commits** cross in either direction; the baked instructions tell agents to
  work on a branch and commit early.

`sbx-agents` wraps that into five verbs. It's hardcoded to one repo per
environment — `$SBX_WORKSPACE` (GitHub repo `$SBX_GH_REPO`, or the
workspace's `origin` remote if unset) — so it works from any directory, no
`--repo` flag or `cd` needed. Put it on your PATH:
`ln -s "$PWD/sbx-agents" ~/.local/bin/sbx-agents`.

```sh
sbx-agents ls                    # every sandbox's branches + how far ahead of your HEAD
sbx-agents pull claude-1234      # fetch + check the agent's branch out in a worktree at
                                 #   ../<repo>-wt/claude-1234-<branch> (local branch
                                 #   sbx/claude-1234/<branch>) — inspect and run tests
                                 #   there without touching your working tree
sbx-agents push claude-1234 main # the sandbox's clone learns your main (a `git fetch
                                 #   host main` inside); the agent still has to
                                 #   `git rebase host/main`
sbx-agents harvest claude-1234   # stopped sandbox: wake it, fetch everything, stop it
                                 #   again — no need to bring the TUI up just to fetch
sbx-agents clean claude-1234     # undo pull: remove the worktree + sbx/... branch
                                 #   (--force for dirty/unmerged; after sbx rm it also
                                 #   prunes the fetch refs and stale remote)
sbx-agents rm claude-1234        # completely done with it: `sbx rm` + `clean` in one
                                 #   step (--force for a dirty worktree/unmerged branch)
```

A typical session:

```sh
sbx-agents issue claude 1234         # agent works the issue in its own clone
sbx-agents ls                        # claude-1234: fix/payments … [3 ahead of HEAD]
sbx-agents pull claude-1234          # → ../myrepo-wt/claude-1234-fix-payments
(cd ../myrepo-wt/claude-1234-fix-payments && pnpm test)
git commit …                         # meanwhile you commit on main
sbx-agents push claude-1234 main     # then ask the agent to rebase onto host/main
# happy with it: merge sbx/claude-1234/fix-payments as usual, then
sbx-agents rm claude-1234            # destroy the sandbox + drop the worktree/branch
```

Worth knowing:

- `pull`/`push` can omit the sandbox name when this repo has exactly one;
  `pull` defaults to the branch the sandbox has checked out.
- A sandbox woken by `sbx exec` republishes its daemon port but sbx does
  **not** re-add the git remote — `sbx-agents` reads the port from `sbx ls`
  in that case, which is what makes `harvest` work on stopped sandboxes.
- Uncommitted sandbox changes never cross; `sbx cp` remains the escape hatch
  for stray files.

## GitHub over SSH

Sandboxes reach GitHub over HTTPS out of the box; SSH remotes
(`git@github.com:owner/repo.git`) need a key. The key is **never baked into an
image** — images are pushed to a registry, and a secret in a layer is
published. Instead the host mounts a dedicated key directory at sandbox
creation and `sbx-agent setup-ssh` installs it at launch.

The key in `~/.ssh/sandbox` can be registered as an **account-level SSH key**
(given a descriptive name, e.g. "Sandboxes"), not a per-repo deploy key, so it
reaches every repo on the account — nothing needs granting per repo. Note the
trade-off that comes with it: an account key carries **write** access to
everything you can push to, from inside a sandbox, whereas a deploy key would
be scoped to one repo and can be read-only.

One-time host setup — a **dedicated keypair used only by sandboxes**, never
your personal key:

```sh
mkdir -p ~/.ssh/sandbox
ssh-keygen -t ed25519 -f ~/.ssh/sandbox/id_ed25519 -C "sandbox"
```

Then grant `~/.ssh/sandbox/id_ed25519.pub` access on GitHub — narrowest grant
first:

- **Deploy key** (repo → Settings → Deploy keys): scoped to a single
  repository and read-only by default; tick "Allow write access" only if
  sandboxes should push. The right choice when agents work on a known repo.
- **Machine-user key**: a separate GitHub account holding only this key,
  invited to just the repos it needs — multi-repo access without exposing your
  main account. Read-only vs read-write is controlled by the role you give it.
- Adding the key to your own account also works, but grants sandboxes
  everything your account can reach — avoid it.

One-time policy: the sandbox proxy default-denies non-HTTPS egress, and
`github.com` is only pre-allowed for 443:

```sh
sbx policy allow network "github.com:22"
```

Per sandbox, mount the key directory as an extra **read-only** workspace at
creation (extra workspaces mount at the same absolute path as on the host):

```sh
sbx create --clone -e TZ=UTC -t <image> claude . ~/.ssh/sandbox:ro
```

At every launch the claude/codex shims run `sbx-agent setup-ssh`: bind mounts
preserve host ownership and ssh insists on a 600 key owned by the current
user, so it copies the key to `~/.ssh/github_sandbox` (0600, agent-owned),
appends a grep-guarded `Host github.com` block to `~/.ssh/config`
(`IdentitiesOnly yes`), and installs GitHub's published host keys into
`~/.ssh/known_hosts` (baked in — no `ssh-keyscan` prompt). A non-standard key
location can be pointed at with `-e SANDBOX_GITHUB_KEY=/abs/path/to/key` at
creation.

Everything degrades gracefully: with no key mounted this is a silent no-op
and the sandbox boots exactly as before, HTTPS-only. Verify with
`ssh -T git@github.com` (expect the "successfully authenticated" banner).

## Dev stack

The images bake the target project's own dev stack — PostgreSQL 17
(`pg_cron`, `pg_stat_statements`, `btree_gin`, `pg_trgm`, `pgcrypto`,
`unaccent`; schema layout matching `postgres/Dockerfile` /
`postgres/init-db.sql` exactly), Node, TypeScript, and a real browser for
screenshots and video — and the project's own `manifest` CLI
(`apps/cli/manifest.sh`) is the tool for everything workspace-specific:
tests, migrations, seeding.

`sbx-agent container-init`, baked as the image's `ENTRYPOINT`, starts Postgres
before any agent CLI runs — so `sbx exec` and a bare `docker run` see it
ready too, not just whichever agent's shim happens to fire. The
`manifest`/`pgboss` schema bootstrap happens later, in the shim's `launch`
step: a `--clone` sandbox's workspace can still be populating (git clone +
`pnpm install`) when the entrypoint runs, so bootstrapping there raced an
empty checkout; by the time `launch` reaches it the workspace is guaranteed
present. On top of that, `pnpm manifest db migrate` (idempotent, unlike the
destructive `db reset`) runs at every agent launch, so a container that
stays up across many re-attaches still picks up migrations landed since the
last one:

```sh
pnpm manifest db status    # migration status, connection info
pnpm manifest db migrate   # apply pending migrations (safe; runs automatically too)
pnpm manifest db reset     # destructive: drop + rebuild + re-migrate + regen types
pnpm manifest test unit|api|e2e   # the sanctioned test runner — manages its own
                                  # isolated schema/server for api/e2e
```

Four things the stock base image gets wrong, each fixed in
`config/build-install.sh` (worth knowing because the symptoms point nowhere
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
3. **PostgreSQL 17 isn't in Ubuntu 26.04's own archive** (only 18 is), and
   PGDG's apt repo ships `.deb`s built against a real release's exact library
   versions that 26.04 doesn't have — a genuine cross-release ABI mismatch, not
   something an `/etc/os-release` spoof can fix (confirmed by hitting exactly
   that dependency conflict). So `build-install.sh` compiles PostgreSQL 17.7
   itself from source against whatever 26.04 actually ships, with a
   self-managed cluster (`initdb` + `pg_ctl`, not `postgresql-common`) — and
   builds `pg_cron` via PGXS against that same self-built `pg_config`.
4. **Playwright has no `ubuntu26.04-arm64` build** and refuses before
   downloading. `build-install.sh` presents 24.04 in `/etc/os-release` for the
   duration of the install; the noble arm64 binaries run fine on 26.04's newer
   glibc.

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

Postgres is pinned to **17.7** to match the target project's own
`postgres/Dockerfile` (`FROM postgres:17.7`) — `pg_dump` output is not
identical across majors, and `schema.sql` / the migration baseline assume 17.
Don't commit schema dumps generated in a sandbox.

`sslmode=require` (a common `DATABASE_SSL_MODE` default) only encrypts — it
never verifies the cert or hostname — so the self-signed cert the image
issues needs no CA trust-store wiring, unlike a `verify-full` setup. Adjust
this section for whatever the target project's own connection config
actually does.

## Stopping and resuming

Exiting an agent's TUI leaves its sandbox running in the background;
`sbx stop <sandbox>` shuts it down cleanly. Stopped sandboxes retain all
state and restart automatically on the next `sbx run`. A computer restart
just stops them the same way — nothing is lost.

After a reboot: start Docker Desktop, run `./host-services.sh` and bring the
`gitnexus` compose service back up (see "Workflow"), then re-attach from the
workspace dir. Each agent resumes its previous conversation with its own
flag, passed after `--`:

```sh
sbx run claude -- --continue     # resume the last claude conversation
sbx run codex -- resume --last   # resume the last codex session (or `resume` for a picker)
```

`sbx rm` is what actually discards state: the container filesystem — and
with it codex session history — is gone. Claude's conversation history lives
on sbx-managed persistent volumes (`~/.claude/projects` etc.) and survives
even removal/recreation. For a `--clone` sandbox, prefer `sbx-agents rm` over
bare `sbx rm` — it also drops the host-side worktree, local branch, and
stale remote (see "Clone mode: syncing work").

## Agent-to-agent review

Agents cannot run each other's CLIs inside their own sandbox: sbx injects
credentials and allows API domains per agent manifest, so e.g. `codex` inside
the claude sandbox has no OpenAI key and no route to `api.openai.com`.
Instead, `host-services.sh` serves an MCP server (`agents`, registered in
both templates) with two tools:

- `ask_agent({agent, prompt, workdir})` — starts the target agent **headlessly
  inside its own sandbox** via `sbx exec` (`claude -p` / `codex exec`),
  against the same shared workspace. `workdir` is the absolute workspace
  path, used to find the peer's sandbox (falls back to the default
  `<agent>-<workdir>` name; pass `sandbox` to override). The call blocks up
  to `wait_seconds` (default 50): a fast peer's answer is returned directly;
  a slow one gets you a **job id** while it keeps running on the host (up to
  `timeout_seconds`, default/max 1h).
- `get_agent_response({job_id})` — long-poll a running job: blocks up to
  `wait_seconds` (default 50) and returns either the final answer or a status
  line (elapsed time + tail of the peer's output so far). Finished answers
  stay fetchable for 6h, surviving any client-side timeout or dropped
  connection in between.

The short per-call window is deliberate: it sits under every MCP client's
tool-timeout floor (codex defaults to 60s), so a 45-minute adversarial review
is a series of cheap 50s polls instead of one fragile hour-long HTTP request.

So with claude and codex sandboxes on the same workspace, you can tell
claude: *"implement X, then ask codex to review your diff"* — claude calls
`ask_agent(agent: "codex", prompt: "Review the uncommitted changes…",
workdir: "<workspace>")` and polls `get_agent_response` until the review
comes back as text. The peer sees
uncommitted changes (same bind-mount). Requirements: the bridge running on
the host, the `localhost:4748` policy allow, and a signed-in sandbox for the
target agent. The instruction files tell agents not to chain `ask_agent`
calls (no review-of-review loops).

## How it works

- Sandboxes do **not** sync host `~/.claude`; the claude image bakes
  `~/.claude/CLAUDE.md` and the gitnexus MCP registration in `~/.claude.json`.
- sbx **re-seeds `~/.claude.json` at sandbox creation**, clobbering the baked
  MCP registration. The Dockerfile moves the native-install launcher symlink
  (`/home/agent/.local/bin/claude`) to `claude-real` and puts a shim in its
  place that re-asserts the registration via `config/gitnexus-mcp.cjs` on every
  launch, then `exec`s `claude-real`. (Auto-updates would rewrite the launcher
  path over the shim; sbx seeds `autoUpdates: false`, so this holds.)
- The codex image uses the same shim trick with less ceremony: sbx seeds
  `~/.codex/config.toml` unconditionally at sandbox (re)create, so
  `codex-shim.sh` — at `/home/agent/.local/bin/codex`, which precedes the real
  npm-global binary on PATH, no `mv` needed — delegates to `sbx-agent launch
  codex`, which rewrites the gitnexus/agent-bridge blocks (stripped and
  re-appended on every launch, so a stale URL or setting never survives)
  before `exec`ing the real codex. Global instructions live at
  `~/.codex/AGENTS.md`.
- The workspace mounts at the same absolute path as on the host — never bake
  files under a workspace path (the mount would shadow them). Project-specific
  skills belong in the workspace's own `.claude/skills`/`.agents/skills` (the
  target project may already have these), which each agent discovers
  natively — nothing in this repo needs to deliver skills.
- gitnexus itself never runs in the sandbox; MCP traffic goes to the host via
  `http://host.docker.internal:4747/api/mcp`.

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
- **gitnexus missing from codex's MCP servers, or its URL/timeout looks
  stale**: `~/.codex/config.toml` was re-seeded and the shim didn't run — check
  that `/home/agent/.local/bin/codex` is the shim script, and re-assert
  manually with `sbx-agent gitnexus-codex` (safe to re-run any time — it
  strips and re-appends the `[mcp_servers.gitnexus]`/`[mcp_servers.agents]`
  blocks rather than skipping when they already exist).
- **Postgres isn't up / `pnpm manifest db status` shows nothing listening**:
  `sbx-agent container-init` runs once as the image's `ENTRYPOINT`, before the
  agent CLI — check `pg_isready -h localhost -p 5432` and
  `sudo tail -30 /var/log/postgresql/postgresql-17-main.log`. A `docker exec`
  into the container (or `sbx exec`) re-triggers nothing; only a fresh
  container start (or sandbox stop/resume) re-runs the entrypoint.
- **`postgres/init-db.sql` bootstrap failed**: this step warns to stderr
  rather than blocking the launch. Re-run it by hand: `sudo -u postgres psql
  -f "$SBX_WORKSPACE/postgres/init-db.sql"`.
- **`manifest db migrate` failed at launch**: non-fatal by design (the shims
  warn and continue). Diagnose with `pnpm manifest db status`, then re-run
  `pnpm manifest db migrate` by hand.
- **codex not signed in**: run `sbx secret set -g openai --oauth` on the host,
  then recreate the sandbox.
- **`ask_agent` times out**: individual MCP calls should never come near a
  client timeout anymore — `ask_agent`/`get_agent_response` block only
  `wait_seconds` (default 50s) per call while the peer runs asynchronously on
  the host (job capped at 1h via `timeout_seconds`). If a caller still reports
  a tool timeout, either the bridge on the host is an old pre-job version
  (restart `./host-services.sh`), or the caller passed a large explicit
  `wait_seconds` that exceeds its own client timeout — claude's is
  `MCP_TOOL_TIMEOUT=3600000` in `config/claude-settings.json`, codex's is
  `tool_timeout_sec = 3600` set by `sbx-agent gitnexus-codex`, which rewrites
  the block on every launch so this can't go stale. Stick to the default
  `wait_seconds` and poll. A job
  erroring with "peer run killed after 3600s" genuinely exceeded the 1h cap —
  split the review into narrower prompts (one subsystem or one diff per call).
- **`ask_agent` fails or hangs**: check the bridge is running on the host
  (`./host-services.sh`) and `localhost:4748` is allowed (`sbx policy
  log`). "no <agent> sandbox found" means the target agent has no sandbox on
  that workspace — create one. A job that stays "still running" with no
  output tail usually means the target sandbox is not signed in (the headless
  CLI is waiting on a login prompt); run the agent interactively once to
  authenticate. "unknown job" from `get_agent_response` means the bridge
  restarted since the job started — re-issue the `ask_agent` call.
- **git-over-SSH hangs or times out**: check `sbx policy log` for a blocked
  `github.com:22` — the one-time `sbx policy allow network "github.com:22"` is
  missing. If port 22 egress is blocked end to end (some networks), the baked
  `~/.ssh/config` also declares `ssh.github.com:443` — point the remote at
  `ssh://git@ssh.github.com:443/owner/repo.git`.
- **`git@github.com: Permission denied (publickey)`**: no key was provisioned
  (the sandbox was created without the `~/.ssh/sandbox:ro` mount — recreate it
  with the mount), the shim didn't run (`ls -l ~/.ssh/github_sandbox`;
  re-assert with `sbx-agent setup-ssh`), or the public key was never granted
  access on GitHub. See "GitHub over SSH".
- **Stale gitnexus index**: re-run the analyze on the host — never inside the
  sandbox.
