import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, existsSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { facts } from '../src/content/facts.ts';
import {
  pages, faqEntries, faqLd, applicationLd, organizationLd, breadcrumbLd, llmsTxt, robotsTxt, sitemapXml,
  CRAWLERS, OG_IMAGE,
} from '../src/content/seo.ts';
import { supportBlocks } from '../src/content/support.ts';
import { shown, slotsIn, visibleText } from '../src/content/doc.ts';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const withFlags = (over) => ({ ...facts, ...over, platforms: { ...facts.platforms, ...(over.platforms ?? {}) } });
const states = [
  facts,
  withFlags({ storeState: 'live', icloud: true, pro: true, firstRunQuestion: true }),
  withFlags({ platforms: { mac: false } }),
  withFlags({ storeState: 'preorder', platforms: { mac: false } }),
];

test('every page has a unique title and description, in length for search', () => {
  for (const f of states) {
    const list = pages(f);
    assert.equal(new Set(list.map((p) => p.title)).size, list.length);
    assert.equal(new Set(list.map((p) => p.description)).size, list.length);
    for (const p of list) {
      assert.ok(p.title.length <= 65, `${p.id} title ${p.title.length}`);
      assert.ok(p.description.length >= 70 && p.description.length <= 165, `${p.id} description ${p.description.length}`);
      assert.doesNotMatch(p.title + p.description, /[–—]/, 'no dashes');
      assert.match(p.path, /^\/([a-z]+\/)?$/);
    }
  }
});

test('copy has no promo words and no invented ratings', () => {
  const all = states.flatMap((f) => [...pages(f).map((p) => p.description), llmsTxt(f)]).join('\n');
  assert.doesNotMatch(all, /\b(best|revolutionary|powerful|seamless|stunning|ultimate|award|rated|stars?)\b/i);
});

test('sitemap lists every page route in src/app, and only those', () => {
  const routes = [];
  const walk = (dir, rel) => {
    for (const e of readdirSync(join(site, dir), { withFileTypes: true })) {
      if (e.isDirectory()) walk(join(dir, e.name), `${rel}${e.name}/`);
      else if (e.name === 'page.tsx') routes.push(rel);
    }
  };
  walk('src/app', '/');
  const listed = pages(facts).map((p) => p.path).sort();
  assert.deepEqual(listed, routes.sort());
  const xml = sitemapXml(facts);
  for (const p of pages(facts)) assert.ok(xml.includes(`<loc>https://${facts.domain}${p.path}</loc>`), p.path);
  assert.equal((xml.match(/<loc>/g) ?? []).length, routes.length);
  assert.doesNotMatch(xml, /404/);
});

test('robots allows every crawler, AI crawlers included, and points at the sitemap', () => {
  const txt = robotsTxt(facts);
  assert.doesNotMatch(txt, /Disallow:\s*\S/);
  assert.match(txt, /User-agent: \*\nAllow: \/\n/);
  for (const bot of ['GPTBot', 'ClaudeBot', 'PerplexityBot', 'Google-Extended', 'CCBot', 'Applebot-Extended']) {
    assert.ok(CRAWLERS.includes(bot), bot);
    assert.match(txt, new RegExp(`User-agent: ${bot}\\nAllow: /\\n`));
  }
  assert.match(txt, new RegExp(`Sitemap: https://${facts.domain}/sitemap.xml`));
});

test('FAQ JSON-LD matches the visible support answers in every state', () => {
  for (const f of states) {
    const blocks = supportBlocks(f);
    const ld = faqLd(f, blocks);
    assert.equal(ld['@type'], 'FAQPage');
    const questions = shown(f, blocks).filter((b) => b.kind === 'h3').map((b) => b.text);
    assert.deepEqual(ld.mainEntity.map((e) => e.name), questions, 'one entry per visible question, in order');
    const visible = visibleText(f, blocks).join('\n');
    for (const e of ld.mainEntity) {
      assert.equal(e['@type'], 'Question');
      assert.ok(e.acceptedAnswer.text.length > 20);
      // Every visible paragraph under the question is in the answer, in order.
      const lines = visible.split('\n');
      const at = lines.indexOf(e.name, lines.indexOf(e.name) + 1);
      assert.ok(at >= 0, e.name);
      assert.ok(e.acceptedAnswer.text.startsWith(lines[at + 1]), `first paragraph of ${e.name}`);
    }
    // No link markup leaks into an answer. (Owner slots are checked for the current state below; in the
    // live state the page still shows its slot until the owner fills it, and the FAQ mirrors the page.)
    assert.doesNotMatch(JSON.stringify(ld), /\]\(|\[Can/);
  }
});

test('before launch the FAQ says nothing about Pro prices, restore or refunds', () => {
  const text = JSON.stringify(faqLd(facts, supportBlocks(facts)));
  assert.doesNotMatch(text, /Restore|refund|Prompter Pro is one payment|\$/);
  assert.match(text, /no subscription/);
});

test('support FAQ answers carry no slot the owner has not filled', () => {
  const answered = new Set(faqEntries(facts, supportBlocks(facts)).map((e) => e.question));
  assert.ok(answered.size >= 8);
  for (const e of faqEntries(facts, supportBlocks(facts))) assert.doesNotMatch(e.answer, /Owner:/, e.question);
  assert.ok(Array.isArray(slotsIn(facts, supportBlocks(facts))));
});

test('application and organization JSON-LD: facts only, free download, no ratings', () => {
  const app = applicationLd(facts);
  assert.equal(app['@type'], 'MobileApplication');
  assert.equal(app.name, 'Prompter');
  assert.equal(app.offers.price, '0');
  assert.equal(app.offers.priceCurrency, 'USD');
  assert.equal(app.operatingSystem, 'iOS, iPadOS, macOS, watchOS');
  assert.equal(applicationLd(withFlags({ platforms: { mac: false } })).operatingSystem, 'iOS, iPadOS, watchOS');
  assert.equal(app.offers.availability, undefined, 'no availability before the listing exists');
  assert.equal(applicationLd(withFlags({ storeState: 'live' })).offers.availability, 'https://schema.org/InStock');
  assert.doesNotMatch(JSON.stringify(app), /aggregateRating|review|ratingValue|downloadUrl|installUrl/i);
  const org = organizationLd(facts);
  assert.equal(org['@type'], 'Organization');
  assert.equal(org.name, 'Florida Focus Creation LLC');
  assert.equal(org.url, `https://${facts.domain}`);
  assert.doesNotMatch(JSON.stringify(org), /address|telephone|email/i);
});

test('breadcrumbs: home then the page, absolute URLs', () => {
  for (const id of ['support', 'privacy', 'rig']) {
    const b = breadcrumbLd(facts, id);
    assert.equal(b.itemListElement.length, 2);
    assert.equal(b.itemListElement[0].item, `https://${facts.domain}/`);
    assert.equal(b.itemListElement[1].item, `https://${facts.domain}${pages(facts).find((p) => p.id === id).path}`);
  }
});

test('llms.txt states plain facts that are true in the current flag state', () => {
  const txt = llmsTxt(facts);
  assert.match(txt, /^# Prompter\n\n> /);
  assert.match(txt, /not on the App Store yet/);
  assert.match(txt, /iCloud sync \(not available yet\)/);
  assert.match(txt, /\$9\.99/);
  assert.match(llmsTxt(withFlags({ storeState: 'live' })), /Status: on the App Store/);
  assert.doesNotMatch(txt, /[–—]/);
});

test('the Open Graph image exists at 1200 by 630', () => {
  const file = join(site, 'public', OG_IMAGE.path);
  assert.ok(existsSync(file));
  const png = readFileSync(file);
  assert.equal(png.readUInt32BE(16), OG_IMAGE.width);
  assert.equal(png.readUInt32BE(20), OG_IMAGE.height);
  assert.ok(png.length < 600_000);
});
