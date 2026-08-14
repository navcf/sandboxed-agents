#!/usr/bin/env sh
# Host-side services for the sandboxes, in one self-contained script:
#   - gitnexus MCP HTTP server        127.0.0.1:${GITNEXUS_MCP_PORT:-4747}
#   - agent-bridge MCP HTTP server    127.0.0.1:${AGENT_BRIDGE_PORT:-4748}
#
# Sandboxes reach both via host.docker.internal; requires the one-time
#   sbx policy allow network "localhost:4747"
#   sbx policy allow network "localhost:4748"
#
# The agent-bridge lets one sandboxed agent ask another for help (e.g. a code
# review) through a single MCP tool, ask_agent: it runs the target agent
# HEADLESSLY inside its own sandbox via `sbx exec` — where its proxy-managed
# credentials and network policy live — against the same shared workspace.
#
# Ctrl-C stops both servers; if either exits, the other is stopped too so a
# half-running state never lingers.
set -eu
cd "$(dirname "$0")"

export GITNEXUS_MCP_PORT="${GITNEXUS_MCP_PORT:-4747}"
export AGENT_BRIDGE_PORT="${AGENT_BRIDGE_PORT:-4748}"

# Loopback bind — no auth token required. If sandboxes cannot reach it,
# retry with: --host 0.0.0.0 --auth-token <token>
npx -y gitnexus mcp --http -p "$GITNEXUS_MCP_PORT" &
gitnexus=$!

# Stateless streamable-HTTP JSON-RPC, dependency-free (node built-ins only).
node --input-type=module - <<'BRIDGE_EOF' &
import http from 'node:http';
import { spawn } from 'node:child_process';
import { basename } from 'node:path';

const PORT = Number(process.env.AGENT_BRIDGE_PORT || 4748);

// Headless invocations. The prompt is piped via stdin for claude (argv-free)
// and passed as a verbatim argv element otherwise — sbx exec does not go
// through a shell, so no quoting issues. All three CLIs take a model flag.
const AGENTS = {
  claude: (prompt, model) => ({ argv: ['claude', '--dangerously-skip-permissions', ...(model ? ['--model', model] : []), '-p'], stdin: prompt }),
  codex:  (prompt, model) => ({ argv: ['codex', 'exec', '--skip-git-repo-check', ...(model ? ['--model', model] : []), prompt] }),
  // --force: headless cursor-agent otherwise REJECTS every shell command it
  // wants to run (the interactive TUI gets --yolo from sbx; -p mode doesn't),
  // which surfaces as "no git/github access" during reviews.
  cursor: (prompt, model) => ({ argv: ['cursor-agent', '-p', prompt, '--output-format', 'text', '--force', ...(model ? ['--model', model] : [])] }),
};

const TOOL = {
  name: 'ask_agent',
  description:
    'Ask another sandboxed coding agent (claude, codex, or cursor) to perform a task — ' +
    'typically reviewing work in the shared workspace. The peer runs headlessly in its own ' +
    'sandbox on the same workspace files, so reference files/diffs by path in the prompt. ' +
    'Returns the peer\'s final answer as text. Do not call ask_agent from within a request ' +
    'that was itself made via ask_agent.',
  inputSchema: {
    type: 'object',
    properties: {
      agent: { type: 'string', enum: ['claude', 'codex', 'cursor'], description: 'Which agent to ask.' },
      prompt: { type: 'string', description: 'The full task, self-contained: what to do, which files/commits/diffs to look at, and what to return.' },
      workdir: { type: 'string', description: 'Absolute path of the shared workspace (your workspace root). Used to find the peer\'s sandbox.' },
      sandbox: { type: 'string', description: 'Optional explicit sandbox name; overrides workdir-based lookup.' },
      model: { type: 'string', description: 'Optional model for the peer, in that agent\'s own naming (e.g. cursor: "gpt-5.3-codex-high", "composer-2.5", see `cursor-agent models`; claude: "opus", "sonnet"; codex: "gpt-5-codex"). Omit for the agent\'s default.' },
      timeout_seconds: { type: 'number', description: 'Max seconds to wait (default 3600, i.e. 1h).' },
    },
    required: ['agent', 'prompt', 'workdir'],
  },
};

const run = (argv, { stdin, timeoutMs } = {}) =>
  new Promise((resolve) => {
    const p = spawn(argv[0], argv.slice(1), { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '', timedOut = false;
    const t = timeoutMs && setTimeout(() => { timedOut = true; p.kill('SIGKILL'); }, timeoutMs);
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out, err, timedOut }); });
    p.on('error', (e) => { clearTimeout(t); resolve({ code: -1, out, err: String(e), timedOut }); });
    if (stdin) p.stdin.write(stdin);
    p.stdin.end();
  });

async function resolveSandbox(agent, workdir) {
  const { out } = await run(['sbx', 'ls']);
  const rows = out.trim().split('\n').slice(1).map((l) => l.split(/\s{2,}/));
  const match = rows.find((r) => r[1] === agent && (r[4] || '').split(',').map((s) => s.trim()).includes(workdir));
  if (match) return match[0];
  const guess = `${agent}-${basename(workdir)}`;
  if (rows.some((r) => r[0] === guess)) return guess;
  const have = rows.map((r) => `${r[0]} (${r[1]}: ${r[4] || '?'})`).join('; ') || 'none';
  throw new Error(`no ${agent} sandbox found for workspace ${workdir}. Existing sandboxes: ${have}. ` +
    `Create one with: sbx run --no-share-skills -t docker.io/navcf/sandbox-templates:<tag> ${agent} (from the workspace dir), or pass sandbox explicitly.`);
}

async function askAgent({ agent, prompt, workdir, sandbox, model, timeout_seconds }) {
  if (!AGENTS[agent]) throw new Error(`unknown agent ${agent}; use claude, codex, or cursor`);
  const name = sandbox || (await resolveSandbox(agent, workdir));
  const { argv, stdin } = AGENTS[agent](prompt, model);
  const res = await run(['sbx', 'exec', name, ...argv], { stdin, timeoutMs: (timeout_seconds || 3600) * 1000 });
  if (res.timedOut) throw new Error(`ask_agent timed out after ${timeout_seconds || 3600}s; partial output:\n${res.out || res.err}`);
  if (res.code !== 0) throw new Error(`${agent} exited ${res.code}:\n${res.err || res.out}`);
  return res.out.trim() || '(no output)';
}

const rpcResult = (id, result) => ({ jsonrpc: '2.0', id, result });
const rpcError = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

async function handle(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case 'initialize':
      return rpcResult(id, {
        protocolVersion: params?.protocolVersion || '2025-03-26',
        capabilities: { tools: {} },
        serverInfo: { name: 'agent-bridge', version: '1.0.0' },
      });
    case 'ping':
      return rpcResult(id, {});
    case 'tools/list':
      return rpcResult(id, { tools: [TOOL] });
    case 'tools/call': {
      if (params?.name !== TOOL.name) return rpcError(id, -32602, `unknown tool ${params?.name}`);
      try {
        const text = await askAgent(params.arguments || {});
        return rpcResult(id, { content: [{ type: 'text', text }] });
      } catch (e) {
        return rpcResult(id, { content: [{ type: 'text', text: String(e.message || e) }], isError: true });
      }
    }
    default:
      return rpcError(id, -32601, `method not found: ${method}`);
  }
}

http
  .createServer(async (req, res) => {
    if (req.method !== 'POST') {
      res.writeHead(req.method === 'DELETE' ? 200 : 405).end();
      return;
    }
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', async () => {
      let msg;
      try { msg = JSON.parse(body); } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' })
          .end(JSON.stringify(rpcError(null, -32700, 'parse error')));
        return;
      }
      if (msg.id === undefined || msg.id === null) { res.writeHead(202).end(); return; } // notification
      if (msg.method === 'tools/call') {
        // Long-running calls (reviews take minutes) answered as an SSE stream
        // with heartbeat comments: the sandbox egress proxy drops HTTP
        // connections that stay idle for minutes, which lost completed
        // reviews and surfaced as silent client-side timeouts.
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
        const hb = setInterval(() => res.write(': keepalive\n\n'), 15000);
        req.on('close', () => clearInterval(hb));
        const reply = await handle(msg);
        clearInterval(hb);
        res.write(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
        res.end();
        return;
      }
      const reply = await handle(msg);
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(reply));
    });
  })
  .listen(PORT, '127.0.0.1', () => console.log(`agent-bridge MCP listening on 127.0.0.1:${PORT}`));
BRIDGE_EOF
bridge=$!

trap 'kill "$gitnexus" "$bridge" 2>/dev/null || true' INT TERM EXIT

while kill -0 "$gitnexus" 2>/dev/null && kill -0 "$bridge" 2>/dev/null; do
  sleep 1
done
