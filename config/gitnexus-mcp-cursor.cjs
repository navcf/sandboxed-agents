// Merge the host-side MCP registrations (gitnexus + agent-bridge) into
// ~/.cursor/mcp.json. Cursor's remote-server shape is {url} with no type
// field. Idempotent merge — safe to re-run; preserves any other servers.
const fs = require('fs');
const p = process.env.HOME + '/.cursor/mcp.json';
fs.mkdirSync(require('path').dirname(p), { recursive: true });
const j = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
j.mcpServers = {
  ...j.mcpServers,
  gitnexus: { url: 'http://host.docker.internal:4747/mcp' },
  agents: { url: 'http://host.docker.internal:4748/mcp' },
};
fs.writeFileSync(p, JSON.stringify(j, null, 2));
