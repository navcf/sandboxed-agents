#!/usr/bin/env sh
# Host-side agent-bridge MCP HTTP server: 127.0.0.1:${AGENT_BRIDGE_PORT:-4748}.
#
# gitnexus runs separately, as a docker-compose service in the project
# workspace (`docker compose --profile gitnexus up -d gitnexus`);
# this script no longer starts it. Sandboxes reach the bridge via
# host.docker.internal; requires the one-time
#   sbx policy allow network "localhost:4748"
#
# The agent-bridge lets one sandboxed agent ask another for help (e.g. a code
# review) through the MCP tool ask_agent: it runs the target agent HEADLESSLY
# inside its own sandbox via `sbx exec` — where its proxy-managed credentials
# and network policy live — against the same shared workspace.
#
# Long peer runs (30-60 min adversarial reviews) use an async job pattern:
# ask_agent starts the peer immediately and blocks only a short wait window
# (default 50s — safely under every MCP client's tool timeout, incl. codex's
# 60s default). If the peer finishes in the window the answer is returned
# directly; otherwise ask_agent returns a job id and the caller long-polls
# get_agent_response until done. The peer keeps running on the host
# regardless of any client-side timeout or dropped connection, and finished
# results are retained for 6h for re-fetch.
#
# Ctrl-C stops the server.
set -eu
cd "$(dirname "$0")"

export AGENT_BRIDGE_PORT="${AGENT_BRIDGE_PORT:-4748}"

# Stateless streamable-HTTP JSON-RPC, dependency-free (node built-ins only).
node --input-type=module - <<'BRIDGE_EOF' &
import http from 'node:http';
import { spawn } from 'node:child_process';
import { basename } from 'node:path';

const PORT = Number(process.env.AGENT_BRIDGE_PORT || 4748);

// Headless invocations. The prompt is piped via stdin for claude (argv-free)
// and passed as a verbatim argv element otherwise — sbx exec does not go
// through a shell, so no quoting issues. Both CLIs take a model flag.
const AGENTS = {
  claude: (prompt, model) => ({ argv: ['claude', '--dangerously-skip-permissions', ...(model ? ['--model', model] : []), '-p'], stdin: prompt }),
  codex:  (prompt, model) => ({ argv: ['codex', 'exec', '--skip-git-repo-check', ...(model ? ['--model', model] : []), prompt] }),
};

const DEFAULT_WAIT_S = 50;              // per-call block window: under every MCP client's tool-timeout floor
const MAX_JOB_S = 3600;                 // hard cap on a peer run
const RETENTION_MS = 6 * 60 * 60 * 1000; // keep finished jobs 6h for (re-)fetch

const TOOLS = [
  {
    name: 'ask_agent',
    description:
      'Ask another sandboxed coding agent (claude or codex) to perform a task — ' +
      'typically reviewing work in the shared workspace. The peer runs headlessly in its own ' +
      'sandbox on the same workspace files, so reference files/diffs by path in the prompt. ' +
      'Starts the peer immediately and waits up to wait_seconds (default 50) for it to finish: ' +
      'if it finishes in time you get its final answer as text; otherwise you get a job id — ' +
      'the peer KEEPS RUNNING, and you must poll get_agent_response({job_id}) until the answer ' +
      'arrives (long reviews can take 30-60 min; keep polling, do not re-ask). ' +
      'Do not call ask_agent from within a request that was itself made via ask_agent.',
    inputSchema: {
      type: 'object',
      properties: {
        agent: { type: 'string', enum: ['claude', 'codex'], description: 'Which agent to ask.' },
        prompt: { type: 'string', description: 'The full task, self-contained: what to do, which files/commits/diffs to look at, and what to return.' },
        workdir: { type: 'string', description: 'Absolute path of the shared workspace (your workspace root). Used to find the peer\'s sandbox.' },
        sandbox: { type: 'string', description: 'Optional explicit sandbox name; overrides workdir-based lookup.' },
        model: { type: 'string', description: 'Optional model for the peer, in that agent\'s own naming (e.g. claude: "opus", "sonnet"; codex: "gpt-5-codex"). Omit for the agent\'s default.' },
        wait_seconds: { type: 'number', description: 'How long this call blocks waiting for the peer before returning a job id (default 50). Keep it under your own MCP client tool timeout.' },
        timeout_seconds: { type: 'number', description: 'Max total seconds the peer may run before it is killed (default and max 3600, i.e. 1h). Not how long this call blocks — that is wait_seconds.' },
      },
      required: ['agent', 'prompt', 'workdir'],
    },
  },
  {
    name: 'get_agent_response',
    description:
      'Fetch the answer from an ask_agent job. Blocks up to wait_seconds (default 50) for the ' +
      'peer to finish; returns the final answer when done, or a status line (elapsed time + tail ' +
      'of the peer\'s output so far) while it is still running — in that case simply call this ' +
      'again. Finished answers stay fetchable for 6 hours.',
    inputSchema: {
      type: 'object',
      properties: {
        job_id: { type: 'string', description: 'The job id returned by ask_agent.' },
        wait_seconds: { type: 'number', description: 'How long this call blocks waiting for completion (default 50). Keep it under your own MCP client tool timeout.' },
      },
      required: ['job_id'],
    },
  },
];

// sink: optional object whose .out/.err mirror the child's output live, so
// still-running jobs can report progress.
const run = (argv, { stdin, timeoutMs, sink } = {}) =>
  new Promise((resolve) => {
    const p = spawn(argv[0], argv.slice(1), { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '', timedOut = false;
    const t = timeoutMs && setTimeout(() => { timedOut = true; p.kill('SIGKILL'); }, timeoutMs);
    p.stdout.on('data', (d) => { out += d; if (sink) sink.out = out; });
    p.stderr.on('data', (d) => { err += d; if (sink) sink.err = err; });
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
    `Create one with: sbx run -t <your-template-image> ${agent} (from the workspace dir), or pass sandbox explicitly.`);
}

// ---- async job registry -------------------------------------------------
// The bridge process outlives individual HTTP requests, so an in-memory map
// is enough: a peer run survives any client-side timeout or dropped
// connection, and its result waits here until fetched (or 6h pass).
const jobs = new Map();
let jobSeq = 0;

const clampWaitS = (w) => Math.min(Math.max(Number.isFinite(w) ? w : DEFAULT_WAIT_S, 0), MAX_JOB_S);
const elapsedS = (job) => Math.round(((job.doneAt || Date.now()) - job.startedAt) / 1000);

// Resolves when the job finishes or after ms, whichever comes first.
const waitJob = (job, ms) =>
  job.status !== 'running' || ms <= 0
    ? Promise.resolve()
    : new Promise((res) => {
        const wake = () => { clearTimeout(t); res(); };
        const t = setTimeout(() => { job.waiters.delete(wake); res(); }, ms);
        job.waiters.add(wake);
      });

function startJob(args) {
  const id = `job-${Date.now().toString(36)}-${(++jobSeq).toString(36)}`;
  const job = {
    id, agent: args.agent, status: 'running', out: '', err: '',
    startedAt: Date.now(), doneAt: 0,
    capS: Math.min(args.timeout_seconds || MAX_JOB_S, MAX_JOB_S),
    waiters: new Set(),
  };
  jobs.set(id, job);
  (async () => {
    try {
      const name = args.sandbox || (await resolveSandbox(args.agent, args.workdir));
      const { argv, stdin } = AGENTS[args.agent](args.prompt, args.model);
      const res = await run(['sbx', 'exec', name, ...argv], { stdin, timeoutMs: job.capS * 1000, sink: job });
      if (res.timedOut) throw new Error(`peer run killed after ${job.capS}s (timeout_seconds cap); partial output:\n${res.out || res.err}`);
      if (res.code !== 0) throw new Error(`${args.agent} exited ${res.code}:\n${res.err || res.out}`);
      job.result = res.out.trim() || '(no output)';
      job.status = 'done';
    } catch (e) {
      job.status = 'error';
      job.error = String(e.message || e);
    } finally {
      job.doneAt = Date.now();
      for (const wake of job.waiters) wake();
      job.waiters.clear();
    }
  })();
  return job;
}

setInterval(() => {
  const now = Date.now();
  for (const [id, j] of jobs) if (j.doneAt && now - j.doneAt > RETENTION_MS) jobs.delete(id);
}, 10 * 60 * 1000).unref();

function jobReply(job) {
  if (job.status === 'done') return job.result;
  if (job.status === 'error') throw new Error(job.error);
  const tail = (job.out || job.err || '').slice(-1500);
  return (
    `Job ${job.id} (${job.agent}) is still running — ${elapsedS(job)}s elapsed of max ${job.capS}s. ` +
    `The peer keeps working; call get_agent_response({job_id: "${job.id}"}) to keep waiting ` +
    `(each call blocks up to wait_seconds, default ${DEFAULT_WAIT_S}s, then reports status again). ` +
    `Do NOT re-issue ask_agent for the same task.` +
    (tail ? `\n--- peer output so far (tail) ---\n${tail}` : '')
  );
}

async function askAgent(args) {
  if (!AGENTS[args.agent]) throw new Error(`unknown agent ${args.agent}; use claude or codex`);
  const job = startJob(args);
  await waitJob(job, clampWaitS(args.wait_seconds) * 1000);
  return jobReply(job);
}

async function getAgentResponse({ job_id, wait_seconds }) {
  const job = jobs.get(job_id);
  if (!job) {
    const known = [...jobs.keys()].join(', ') || 'none';
    throw new Error(`unknown job ${job_id} (known jobs: ${known}). ` +
      'The bridge may have restarted since the job started; re-issue the ask_agent call.');
  }
  await waitJob(job, clampWaitS(wait_seconds) * 1000);
  return jobReply(job);
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
      return rpcResult(id, { tools: TOOLS });
    case 'tools/call': {
      const impl = { ask_agent: askAgent, get_agent_response: getAgentResponse }[params?.name];
      if (!impl) return rpcError(id, -32602, `unknown tool ${params?.name}`);
      try {
        const text = await impl(params.arguments || {});
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
        // tools/call answered as an SSE stream with heartbeat comments: the
        // sandbox egress proxy drops HTTP connections that stay idle, which
        // lost completed replies and surfaced as silent client-side timeouts.
        // Calls now block at most ~wait_seconds (long work is polled via
        // get_agent_response), but the heartbeat keeps even those windows —
        // and any caller-chosen longer waits — alive through the proxy.
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

trap 'kill "$bridge" 2>/dev/null || true' INT TERM EXIT

wait "$bridge"
