// Merge the host-side MCP server registrations (gitnexus + agent-bridge)
// into ~/.claude.json. Idempotent — safe to re-run; preserves any other
// registered servers.
const fs = require('fs');
const p = process.env.HOME + '/.claude.json';
const j = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
j.mcpServers = {
  ...j.mcpServers,
  gitnexus: { type: 'http', url: 'http://host.docker.internal:4747/mcp' },
  agents: { type: 'http', url: 'http://host.docker.internal:4748/mcp' },
};
fs.writeFileSync(p, JSON.stringify(j, null, 2));
