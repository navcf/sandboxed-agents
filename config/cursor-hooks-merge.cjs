// Register the sessionStart hook in ~/.cursor/hooks.json without disturbing
// rtk's entry. rtk init --global --agent cursor owns the `preToolUse` array in
// this same file and rewrites it, so run this AFTER rtk and merge rather than
// overwrite. Idempotent: guarded on the command string, like the grep guards in
// gitnexus-mcp-codex.sh.
//
// cursor watches hooks.json and reloads it automatically, so no restart is
// needed after this runs.
const fs = require('fs');
const path = require('path');

const CMD = '/usr/local/share/sbx/cursor-session-start.sh';
const p = process.env.HOME + '/.cursor/hooks.json';

fs.mkdirSync(path.dirname(p), { recursive: true });
const j = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};

j.version = j.version || 1;
j.hooks = j.hooks || {};
const entries = Array.isArray(j.hooks.sessionStart) ? j.hooks.sessionStart : [];

if (!entries.some((e) => e && e.command === CMD)) {
  entries.push({ command: CMD, type: 'command' });
}
j.hooks.sessionStart = entries;

fs.writeFileSync(p, JSON.stringify(j, null, 2));
