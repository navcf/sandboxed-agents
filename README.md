# Claude Code sandbox template

Custom [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) template with
RTK, the gitnexus MCP server (host-connected), and skills baked in at build
time. No kits, no runtime init — the sandbox is fully configured before
`claude` launches.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Template image on top of `docker/sandbox-templates:claude-code` |
| `skills.txt` | Declarative skill sources, one `npx skills add` source per line |
| `stage.sh` | Installs sources into `build/.claude/skills/` via the [Vercel skills CLI](https://vercel.com/docs/agent-resources/skills) |
| `skills-local/` | Curated local skills, referenced from the manifest |
| `config/CLAUDE.md` | Baked global agent instructions (RTK + gitnexus usage) |
| `config/gitnexus-mcp.cjs` | Merges the gitnexus MCP entry into `~/.claude.json` |
| `claude-shim.sh` | Baked to `/home/agent/.local/bin/claude` (real launcher moved to `claude-real`); re-asserts config sbx clobbers, then `exec`s the real claude |
| `build.sh` | stage → `docker build` → `docker push` |
| `host-gitnexus.sh` | Host-side gitnexus MCP HTTP server on port 4747 |
| `build/` | Generated build context (never edit; recreated by `stage.sh`) |

## Workflow

```sh
./build.sh          # stage skills, build, push docker.io/navcf/sandbox-templates:claude-code
./host-gitnexus.sh  # on the host, in a separate terminal — serves MCP on :4747

# One-time: the sandbox proxy translates host.docker.internal to the host's
# localhost and default-denies it — allow the gitnexus port:
sbx policy allow network "localhost:4747"

sbx create -t docker.io/navcf/sandbox-templates:claude-code claude /path/to/workspace
sbx run --name <sandbox-name>
```

Override the image ref with `IMAGE=... ./build.sh`.

## Skills

Skills are managed with the [Vercel skills CLI](https://vercel.com/docs/agent-resources/skills).
Each non-comment line in `skills.txt` is passed to
`npx skills add <line> -a claude-code -y --copy`, so any source format the CLI
accepts works:

- `owner/repo` or full GitHub/GitLab/git URLs; pin with
  `https://github.com/<owner>/<repo>/tree/<sha>`.
- `-s <name>` selects skills from multi-skill repos (`-s '*'` for all).
- Local paths — `./` and `../` resolve relative to this directory; `~` expands
  to your home.

`npx skills find <query>` discovers new skills; later entries override earlier
ones on name collision. Inside the sandbox the agent can also run
`npx skills add` itself to install more.

## How it works

- Sandboxes do **not** sync host `~/.claude`; the image bakes
  `~/.claude/skills`, `~/.claude/CLAUDE.md`, RTK hooks (`rtk init --global
  --auto-patch`), and the gitnexus MCP registration in `~/.claude.json`.
- sbx **re-seeds `~/.claude.json` at sandbox creation**, clobbering the baked
  MCP registration. The Dockerfile moves the native-install launcher symlink
  (`/home/agent/.local/bin/claude`) to `claude-real` and puts a shim in its
  place that re-asserts the registration via `config/gitnexus-mcp.cjs` on every
  launch, then `exec`s `claude-real`. (Auto-updates would rewrite the launcher
  path over the shim; sbx seeds `autoUpdates: false`, so this holds.)
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
- **Stale gitnexus index**: re-run the analyze on the host — never inside the
  sandbox.
