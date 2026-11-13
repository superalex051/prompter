import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { facts, creditLine, copyrightLine } from '../src/content/facts.ts';
import { deviceFrames } from '../src/content/device-frames.ts';
import { checkFacts } from '../scripts/check-app-facts.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, '..');
const repo = join(site, '..');

test('facts: price, store state and flags', () => {
  assert.equal(facts.price.amount, '9.99');
  assert.equal(facts.price.currency, 'USD');
  assert.equal(facts.price.pendingStoreKit, true);
  assert.equal(facts.storeState, 'coming-soon');
  assert.equal(typeof facts.icloud, 'boolean');
  assert.equal(typeof facts.pro, 'boolean');
  assert.deepEqual([...facts.platforms], ['iPhone', 'iPad', 'Mac', 'Apple Watch']);
});

test('facts match the app source in this repo', () => {
  assert.deepEqual(checkFacts(), []);
});

test('facts check catches a missing feature file', () => {
  const bad = { ...facts, features: [{ id: 'x', label: 'x', file: 'Nope/Missing.swift', pattern: 'x' }] };
  assert.equal(checkFacts(repo, bad).length, 1);
});

test('credit line and copyright line are exact', () => {
  assert.equal(creditLine, 'Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc.');
  assert.equal(copyrightLine, '© 2026 Florida Focus Creation LLC');
  const footer = readFileSync(join(site, 'src/components/Footer.tsx'), 'utf8');
  assert.match(footer, /creditLine/);
  assert.match(footer, /copyrightLine/);
  for (const label of ['Privacy', 'Support', 'GitHub']) assert.match(footer, new RegExp(label));
});

test('config: static export, pinned versions, no analytics', () => {
  assert.match(readFileSync(join(site, 'next.config.mjs'), 'utf8'), /output:\s*'export'/);
  const pkg = JSON.parse(readFileSync(join(site, 'package.json'), 'utf8'));
  const all = { ...pkg.dependencies, ...pkg.devDependencies };
  for (const [name, version] of Object.entries(all)) {
    assert.match(version, /^\d+\.\d+\.\d+$/, `${name} is not pinned: ${version}`);
  }
  assert.match(all.next, /^16\./);
  assert.match(all.react, /^19\./);
  assert.match(all.tailwindcss, /^4\./);
  const banned = /analytics|speed-insights|gtag|googletagmanager|plausible|sentry/i;
  assert.doesNotMatch(JSON.stringify(all), banned);
  const walk = (dir) => readdirSync(join(site, dir), { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);
  for (const f of walk('src')) assert.doesNotMatch(readFileSync(join(site, f), 'utf8'), banned, f);
});

test('device frames: only https Blob URLs or null, no image files committed', () => {
  for (const [key, url] of Object.entries(deviceFrames)) {
    assert.ok(url === null || /^https:\/\/[a-z0-9-]+\.public\.blob\.vercel-storage\.com\//.test(url), key);
  }
  const walk = (dir) => readdirSync(join(site, dir), { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);
  const images = walk('src').filter((f) => /\.(png|jpe?g|webp|avif)$/i.test(f));
  assert.deepEqual(images, []);
});

test('site rules and ignores are in place', () => {
  assert.equal(readFileSync(join(site, 'CLAUDE.md'), 'utf8').trim(), '@AGENTS.md');
  assert.ok(existsSync(join(site, 'AGENTS.md')));
  const ignore = readFileSync(join(repo, '.gitignore'), 'utf8');
  for (const line of ['website/node_modules', 'website/.next', 'website/out', 'website/.vercel', 'website/.env*.local']) {
    assert.ok(ignore.split('\n').includes(line), line);
  }
});
