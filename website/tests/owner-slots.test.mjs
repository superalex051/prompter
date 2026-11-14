import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { check, findSlots } from '../scripts/check-owner-slots.mjs';

function site(content, outHtml) {
  const r = mkdtempSync(join(tmpdir(), 'slots-'));
  mkdirSync(join(r, 'src', 'content'), { recursive: true });
  writeFileSync(join(r, 'src', 'content', 'page.ts'), content);
  if (outHtml !== undefined) {
    mkdirSync(join(r, 'out'));
    writeFileSync(join(r, 'out', 'index.html'), outHtml);
  }
  return r;
}

const withSlot = "// [Owner: ...] explained here\nexport const a = 'Hello [Owner: a date]';\n";

test('production with an unfilled slot fails and names the file and line', () => {
  const r = check({ env: { VERCEL_ENV: 'production' }, siteRoot: site(withSlot) });
  assert.equal(r.ok, false);
  assert.match(r.report, /src\/content\/page\.ts:2/);
});

test('preview and local builds pass and still list the slots', () => {
  for (const env of [{ VERCEL_ENV: 'preview' }, {}]) {
    const r = check({ env, siteRoot: site(withSlot) });
    assert.equal(r.ok, true);
    assert.match(r.report, /1 still unfilled/);
  }
});

test('production with no slots passes; comments and regex escapes are ignored', () => {
  const clean = "// [Owner: ...] is a slot\nconst re = /(\\[Owner: [^\\]]+\\])/;\nexport const a = 'ok';\n";
  assert.equal(check({ env: { VERCEL_ENV: 'production' }, siteRoot: site(clean) }).ok, true);
});

test('production scan of the built pages fails on a rendered slot', () => {
  const r = check({ env: { VERCEL_ENV: 'production' }, siteRoot: site("export const a = 'x';", '<p>[Owner: a date]</p>'), out: true });
  assert.equal(r.ok, false);
  assert.match(r.report, /out\/index\.html:1/);
});

test('findSlots reports line numbers', () => {
  assert.deepEqual(findSlots('a\nb [Owner: x]').map((h) => h.line), [2]);
});
