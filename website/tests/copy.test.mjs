// The text pages: what shows in each flag state, the owner slots, and the copy rules.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { facts } from '../src/content/facts.ts';
import { tokenize, plain, slotsIn, visibleText } from '../src/content/doc.ts';
import { supportBlocks } from '../src/content/support.ts';
import { privacyBlocks, privacyEffective } from '../src/content/privacy.ts';
import { rigBlocks, rigFilesLine } from '../src/content/rig.ts';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const walk = (dir) => readdirSync(join(site, dir), { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);

const withFlags = (over) => ({ ...facts, ...over, platforms: { ...facts.platforms, ...(over.platforms ?? {}) } });
const live = withFlags({ storeState: 'live' });
const text = (f, blocks) => visibleText(f, blocks).join('\n');

test('inline markup: links, bare URLs, emails and slots', () => {
  const t = tokenize('Email support@useprompter.app. See https://example.com/a. Read the [policy](/privacy/). [Owner: a date]');
  assert.deepEqual(t.filter((k) => k.type !== 'text'), [
    { type: 'link', value: 'support@useprompter.app', href: 'mailto:support@useprompter.app' },
    { type: 'link', value: 'https://example.com/a', href: 'https://example.com/a' },
    { type: 'link', value: 'policy', href: '/privacy/' },
    { type: 'slot', value: '[Owner: a date]' },
  ]);
  assert.equal(plain('Read the [policy](/privacy/).'), 'Read the policy.');
});

test('support before launch: no Pro, price, restore or refund lines', () => {
  const today = text(facts, supportBlocks(facts));
  for (const hidden of ['Restore', 'Refunds', 'Prompter Pro', 'one payment', 'Family Sharing', 'iCloud sync is free']) {
    assert.ok(!today.includes(hidden), hidden);
  }
  assert.match(today, /Prompter has no subscription and won't get one\./);
  assert.match(today, /Mac with macOS 26 or later\./);
  assert.match(today, /We don't offer rig files to download yet\. Printable files for the rig are coming later\./);
  assert.ok(!/isn't on the App Store yet/.test(today));
});

test('support once listed: Pro, price from facts, restore and refunds show', () => {
  const after = text(live, supportBlocks(live));
  assert.match(after, /one payment of \$9\.99 that you keep/);
  assert.match(after, /Restore Prompter Pro/);
  assert.match(after, /reportaproblem\.apple\.com/);
  assert.match(after, /presenting from a Mac, and more than 5 scripts/);
  assert.ok(!/won't get one/.test(after));
  const noMac = withFlags({ storeState: 'live', platforms: { mac: false } });
  const noMacText = text(noMac, supportBlocks(noMac));
  assert.match(noMacText, /Prompter for Mac isn't on the App Store yet/);
  assert.match(noMacText, /every iPhone and iPad signed in/);
  assert.ok(!/Mac with macOS/.test(noMacText));
});

test('privacy before launch: no iCloud or purchase sections', () => {
  const today = text(facts, privacyBlocks(facts));
  for (const hidden of ['Purchases', 'iCloud key-value', 'Data Not Collected', 'campaign tag']) {
    assert.ok(!today.includes(hidden), hidden);
  }
  assert.match(today, /The Prompter app collects no data\./);
  assert.match(today, /useprompter\.app sets no cookies/);
  assert.match(today, /passes through Namecheap's email forwarding to Google Workspace/);
  const both = withFlags({ storeState: 'live', icloud: true });
  const later = text(both, privacyBlocks(both));
  for (const shown of ['Purchases', 'iCloud key-value', 'Data Not Collected', 'campaign tag']) assert.ok(later.includes(shown), shown);
});

test('rig guide: first-launch and Pro parts wait for their flags, files line matches the band', () => {
  const today = text(facts, rigBlocks());
  assert.ok(!today.includes('Set up on first launch'));
  assert.ok(!today.includes('part of Prompter Pro'));
  assert.ok(today.includes(rigFilesLine));
  assert.equal(rigFilesLine, 'Printable files for the rig are coming later.');
  assert.ok(text(withFlags({ firstRunQuestion: true }), rigBlocks()).includes('Set up on first launch'));
  assert.ok(!/download (the|our) files|free files/i.test(today));
});

test('owner slots that show today are exactly these', () => {
  assert.deepEqual(slotsIn(facts, supportBlocks(facts)), []);
  assert.ok(text(facts, supportBlocks(facts)).includes('We reply within 2 business days.'));
  assert.ok(text(facts, privacyBlocks(facts)).includes('we delete them 1 year after the last message.'));
  assert.deepEqual(
    [privacyEffective, ...slotsIn(facts, privacyBlocks(facts))].map((s) => s.slice(s.indexOf('[Owner:'), s.indexOf('[Owner:') + 40)),
    [
      '[Owner: effective date]',
      '[Owner: at REL-22, look at this prompt o',
      '[Owner: confirm the log retention for th',
    ],
  );
  assert.deepEqual(slotsIn(facts, rigBlocks()), ['[Owner: a photo of your rig]']);
});

test('ids are unique on each page', () => {
  for (const blocks of [supportBlocks(live), privacyBlocks(withFlags({ storeState: 'live', icloud: true })), rigBlocks()]) {
    const ids = blocks.filter((b) => 'id' in b).map((b) => b.id);
    assert.equal(new Set(ids).size, ids.length);
  }
});

test('copy rules: no dashes, Apple Watch naming, no personal names in the source', () => {
  const files = walk('src').filter((f) => /\.(ts|tsx|css)$/.test(f));
  for (const f of files) {
    const src = readFileSync(join(site, f), 'utf8');
    assert.doesNotMatch(src, /[–—]/, `${f} has an en or em dash`);
    // Slots are labeled [Owner: ...]; no other label (a personal name never goes in this public repo).
    for (const m of src.matchAll(/\[([A-Z][a-z]+): /g)) assert.equal(m[1], 'Owner', `${f} has a slot labeled ${m[1]}`);
  }
  const everything = [
    ...visibleText(live, supportBlocks(live)),
    ...visibleText(withFlags({ storeState: 'live', icloud: true }), privacyBlocks(withFlags({ storeState: 'live', icloud: true }))),
    ...visibleText(withFlags({ storeState: 'live', firstRunQuestion: true }), rigBlocks()),
  ].join('\n');
  assert.doesNotMatch(everything, /\bthe Apple Watch\b/i);
  assert.doesNotMatch(everything.replace(/Apple Watch/g, ''), /\bWatch\b/);
});
