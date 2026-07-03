// Merge the gitnexus MCP registration into ~/.claude.json (user scope).
// Run at image build AND from the claude shim at every launch: sbx re-seeds
// ~/.claude.json during sandbox creation, clobbering config baked into the image.
const fs = require('fs');
const p = process.env.HOME + '/.claude.json';
const j = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
j.mcpServers = {
  ...j.mcpServers,
  gitnexus: { type: 'http', url: 'http://host.docker.internal:4747/mcp' },
};
fs.writeFileSync(p, JSON.stringify(j, null, 2));
