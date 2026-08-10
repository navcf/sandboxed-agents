// Deep-merge the build-time settings snapshot (custom settings + rtk hooks)
// into ~/.claude/settings.json. sbx rewrites settings.json unconditionally at
// sandbox (re)create — bypass flags, model, theme — wiping everything baked.
// Snapshot keys win on conflict; sbx-seeded keys the snapshot doesn't define
// are preserved.
const fs = require('fs');
const src = '/usr/local/share/sbx/claude-settings.json';
const dst = process.env.HOME + '/.claude/settings.json';
const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
const merge = (a, b) => {
  const out = { ...a };
  for (const [k, v] of Object.entries(b)) {
    out[k] = isObj(v) && isObj(a[k]) ? merge(a[k], v) : v;
  }
  return out;
};
fs.mkdirSync(require('path').dirname(dst), { recursive: true });
const cur = fs.existsSync(dst) ? JSON.parse(fs.readFileSync(dst, 'utf8')) : {};
const snap = JSON.parse(fs.readFileSync(src, 'utf8'));
fs.writeFileSync(dst, JSON.stringify(merge(cur, snap), null, 2));
