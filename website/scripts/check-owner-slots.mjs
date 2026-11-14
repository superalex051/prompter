// Production guard: the live site must never show an unfilled `[Owner: ...]` slot.
//   node scripts/check-owner-slots.mjs          scan the source content (run before `next build`)
//   node scripts/check-owner-slots.mjs --out    scan the built pages in out/ (run after `next build`)
// It only fails when VERCEL_ENV is "production". Preview and local builds keep showing the slots.
import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const SLOT = /(?<!\\)\[Owner:/;

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else yield p;
  }
}

/** Lines in `text` that hold a slot. Source comments are skipped, they only describe the syntax. */
export function findSlots(text, { skipComments = true } = {}) {
  const hits = [];
  text.split('\n').forEach((line, i) => {
    if (skipComments && /^\s*(\/\/|\*|\/\*)/.test(line)) return;
    if (SLOT.test(line)) hits.push({ line: i + 1, text: line.trim().slice(0, 140) });
  });
  return hits;
}

/** Returns { ok, report } for the given env and folders. */
export function check({ env = process.env, siteRoot = root, out = false } = {}) {
  const production = env.VERCEL_ENV === 'production';
  const dir = out ? join(siteRoot, 'out') : join(siteRoot, 'src', 'content');
  const files = existsSync(dir) ? [...walk(dir)].filter((f) => (out ? /\.(html|txt|xml|json)$/.test(f) : /\.(ts|tsx)$/.test(f))) : [];
  const found = [];
  for (const f of files) {
    for (const h of findSlots(readFileSync(f, 'utf8'), { skipComments: !out })) found.push({ file: relative(siteRoot, f), ...h });
  }
  const lines = found.map((h) => `  ${h.file}:${h.line}  ${h.text}`);
  if (!found.length) return { ok: true, report: 'owner slots: none left' };
  if (!production) return { ok: true, report: `owner slots: ${found.length} still unfilled (fine outside production)\n${lines.join('\n')}` };
  return { ok: false, report: `owner slots: ${found.length} unfilled slot(s), and VERCEL_ENV=production refuses to build them:\n${lines.join('\n')}` };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { ok, report } = check({ out: process.argv.includes('--out') });
  console[ok ? 'log' : 'error'](report);
  process.exit(ok ? 0 : 1);
}
