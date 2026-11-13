import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { facts, copyrightLine } from '../src/content/facts.ts';
import {
  creditLine, subhead, deviceList, priceLabel, proItems, freeItems, isListed, joinAnd,
} from '../src/content/claims.ts';
import { deviceFrames } from '../src/content/device-frames.ts';
import { checkFacts } from '../scripts/check-app-facts.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, '..');
const repo = join(site, '..');

const walk = (dir) => readdirSync(join(site, dir), { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);

const withFlags = (over) => ({
  ...facts,
  ...over,
  platforms: { ...facts.platforms, ...(over.platforms ?? {}) },
});

test('facts: price, store state and flags', () => {
  assert.equal(facts.price.amount, '9.99');
  assert.equal(facts.price.currency, 'USD');
  assert.equal(facts.price.symbol, '$');
  assert.equal(facts.price.pendingStoreKit, true);
  assert.equal(facts.storeState, 'coming-soon');
  assert.equal(facts.icloud, false);
  assert.equal(facts.pro, false);
  assert.equal(facts.firstRunQuestion, false);
  assert.deepEqual(facts.platforms, { iphone: true, ipad: true, mac: true, watch: true });
  assert.equal(facts.domain, 'useprompter.app');
  assert.equal(facts.supportEmail, 'support@useprompter.app');
  for (const key of ['rig', 'privacy', 'support']) assert.match(facts.links[key], /^\/[a-z]+\/$/, key);
});

test('facts match the app source in this repo', () => {
  assert.deepEqual(checkFacts(), []);
});

test('facts check catches a missing feature file and a missing platform', () => {
  const bad = { ...facts, features: [{ id: 'x', label: 'x', file: 'Nope/Missing.swift', pattern: 'x' }] };
  assert.equal(checkFacts(repo, bad).length, 1);
  assert.equal(checkFacts(join(repo, 'website'), { ...facts, features: [] }).length, 2);
});

test('claims: subhead and device list follow the Mac flag', () => {
  assert.equal(joinAnd(['a', 'b', 'c']), 'a, b and c');
  assert.equal(deviceList(facts), 'iPhone, iPad and Mac');
  assert.equal(subhead(facts), 'A teleprompter for iPhone, iPad and Mac. Run it from your Apple Watch.');
  const noMac = withFlags({ platforms: { mac: false } });
  assert.equal(subhead(noMac), 'A teleprompter for iPhone and iPad. Run it from your Apple Watch.');
});

test('claims: credit line per store state and Mac flag', () => {
  assert.equal(
    creditLine(facts),
    'Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc., registered in the U.S. and other countries. App Store is a service mark of Apple Inc.',
  );
  const live = withFlags({ storeState: 'live' });
  assert.match(creditLine(live), /^Apple, the Apple logo, iPhone, iPad, Mac and Apple Watch are trademarks/);
  assert.match(creditLine(withFlags({ storeState: 'preorder' })), /the Apple logo/);
  const noMac = withFlags({ platforms: { mac: false } });
  assert.match(creditLine(noMac), /^Apple, iPhone, iPad and Apple Watch are trademarks/);
  assert.equal(copyrightLine, '© 2026 Florida Focus Creation LLC');
});

test('claims: price and the Pro and free lists come from facts', () => {
  assert.equal(priceLabel(facts), '$9.99');
  assert.equal(priceLabel(withFlags({ price: { ...facts.price, amount: '7.99' } })), '$7.99');
  assert.deepEqual(proItems(facts).map((i) => i.text), [
    'Voice-follow', 'Apple Watch, Siri and Shortcuts as remotes', 'Presenting from a Mac', 'More than 5 scripts',
  ]);
  assert.ok(!proItems(withFlags({ platforms: { mac: false } })).some((i) => /Mac/.test(i.text)));
  const icloud = freeItems(facts).find((i) => i.text === 'iCloud sync');
  assert.equal(icloud.soon, true);
  assert.equal(freeItems(withFlags({ icloud: true })).find((i) => i.text === 'iCloud sync').soon, false);
  assert.equal(isListed(facts), false);
});

test('no price typed outside facts.ts', () => {
  for (const f of walk('src')) {
    if (f.endsWith('facts.ts')) continue;
    assert.doesNotMatch(readFileSync(join(site, f), 'utf8'), /9\.99/, f);
  }
});

test('footer prints the credit line, the copyright line and its links', () => {
  const footer = readFileSync(join(site, 'src/components/Footer.tsx'), 'utf8');
  assert.match(footer, /creditLine\(facts\)/);
  assert.match(footer, /copyrightLine/);
  for (const label of ['The rig', 'Privacy', 'Support', 'GitHub']) assert.match(footer, new RegExp(`>${label}<`));
});

test('config: static export, pinned versions, dev port, no trackers', () => {
  assert.match(readFileSync(join(site, 'next.config.mjs'), 'utf8'), /output:\s*'export'/);
  const pkg = JSON.parse(readFileSync(join(site, 'package.json'), 'utf8'));
  assert.equal(pkg.scripts.dev, 'next dev -p 4519');
  const all = { ...pkg.dependencies, ...pkg.devDependencies };
  for (const [name, version] of Object.entries(all)) {
    assert.match(version, /^\d+\.\d+\.\d+$/, `${name} is not pinned: ${version}`);
  }
  assert.match(all.next, /^16\./);
  assert.match(all.react, /^19\./);
  assert.match(all.tailwindcss, /^4\./);
  // Package names and script hosts of analytics and tracking tools. The privacy text may say "analytics".
  assert.doesNotMatch(Object.keys(all).join(' '), /analytics|speed-insights|gtag|plausible|sentry|posthog|mixpanel|segment|amplitude|hotjar/i);
  const trackers = /@vercel\/(analytics|speed-insights)|googletagmanager|google-analytics|gtag\(|plausible\.io|@sentry\/|posthog|mixpanel|hotjar|cdn\.segment/i;
  for (const f of walk('src')) assert.doesNotMatch(readFileSync(join(site, f), 'utf8'), trackers, f);
});

test('images: only the four app screenshots, no Apple device images', () => {
  for (const [key, url] of Object.entries(deviceFrames)) {
    assert.ok(url === null || /^https:\/\/[a-z0-9-]+\.public\.blob\.vercel-storage\.com\//.test(url), key);
  }
  assert.deepEqual(walk('src').filter((f) => /\.(png|jpe?g|webp|avif|gif)$/i.test(f)), []);
  assert.deepEqual(walk('public').sort(), [
    'public/shots/m1-library.png',
    'public/shots/m2-playing-mirrored.png',
    'public/shots/m3-watch-playing.png',
    'public/shots/m4-voice-following-1.png',
  ]);
});

test('site rules and ignores are in place', () => {
  assert.equal(readFileSync(join(site, 'CLAUDE.md'), 'utf8').trim(), '@AGENTS.md');
  assert.ok(existsSync(join(site, 'AGENTS.md')));
  const ignore = readFileSync(join(repo, '.gitignore'), 'utf8');
  for (const line of ['website/node_modules', 'website/.next', 'website/out', 'website/.vercel', 'website/.env*.local']) {
    assert.ok(ignore.split('\n').includes(line), line);
  }
});
