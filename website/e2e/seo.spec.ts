import { test, expect } from '@playwright/test';
import { facts } from '../src/content/facts.ts';
import { pages, CRAWLERS } from '../src/content/seo.ts';

// Reads the built pages as a crawler would. The same on every browser, so run it once.
test.beforeEach(({}, info) => {
  test.skip(info.project.name !== 'chromium-1440', 'one project is enough');
});

const origin = `https://${facts.domain}`;
const norm = (s: string) => s.replace(/\s+/g, ' ').trim();

for (const p of pages(facts)) {
  test(`${p.path}: title, description, canonical, cards, JSON-LD`, async ({ page }) => {
    await page.goto(p.path);
    await expect(page).toHaveTitle(p.title);
    const meta = (sel: string) => page.locator(sel).getAttribute('content');
    expect(await meta('meta[name="description"]')).toBe(p.description);
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', `${origin}${p.path}`);
    expect(await meta('meta[property="og:title"]')).toBe(p.title);
    expect(await meta('meta[property="og:description"]')).toBe(p.description);
    expect(await meta('meta[property="og:url"]')).toBe(`${origin}${p.path}`);
    expect(await meta('meta[property="og:image"]')).toBe(`${origin}/og.png`);
    expect(await meta('meta[name="twitter:card"]')).toBe('summary_large_image');
    expect(await meta('meta[name="twitter:image"]')).toBe(`${origin}/og.png`);
    await expect(page.locator('meta[name="robots"][content*="noindex"]')).toHaveCount(0);
    await expect(page.locator('h1')).toHaveCount(1);

    const blocks = await page.locator('script[type="application/ld+json"]').allTextContents();
    const types = blocks.map((b) => JSON.parse(b)['@type']);
    if (p.id === 'home') expect(types).toEqual(['Organization', 'MobileApplication']);
    else if (p.id === 'support') expect(types).toEqual(['FAQPage', 'BreadcrumbList']);
    else expect(types).toEqual(['BreadcrumbList']);
  });
}

test('FAQ JSON-LD equals the answers shown on the support page', async ({ page }) => {
  await page.goto('/support/');
  const ld = JSON.parse((await page.locator('script[type="application/ld+json"]').first().textContent()) ?? '{}');
  const shown = await page.evaluate(() => {
    const out: { q: string; a: string }[] = [];
    document.querySelectorAll('.s-doc h3').forEach((h) => {
      const parts: string[] = [];
      for (let el = h.nextElementSibling; el && !/^H[23]$/.test(el.tagName); el = el.nextElementSibling) {
        if (el.tagName === 'P') parts.push(el.textContent ?? '');
        else if (el.matches('ul, ol') || el.querySelector('p, li')) {
          el.querySelectorAll('li, p').forEach((n) => parts.push(n.textContent ?? ''));
        }
      }
      out.push({ q: h.textContent ?? '', a: parts.join(' ') });
    });
    return out;
  });
  expect(ld.mainEntity.length).toBe(shown.length);
  ld.mainEntity.forEach((e: { name: string; acceptedAnswer: { text: string } }, i: number) => {
    expect(norm(e.name)).toBe(norm(shown[i].q));
    expect(norm(e.acceptedAnswer.text)).toBe(norm(shown[i].a));
  });
});

test('404 is noindex and not in the sitemap', async ({ request, page }) => {
  const res = await request.get('/nope/');
  expect(res.status()).toBe(404);
  await page.goto('/nope/');
  // Next adds its own noindex for not-found pages as well, so there can be two tags. All must say noindex.
  const robots = await page.locator('meta[name="robots"]').evaluateAll((els) => els.map((e) => e.getAttribute('content')));
  expect(robots.length).toBeGreaterThan(0);
  for (const r of robots) expect(r).toContain('noindex');
  const sitemap = await (await request.get('/sitemap.xml')).text();
  expect(sitemap).not.toContain('nope');
});

test('sitemap.xml, robots.txt, llms.txt and og.png are served', async ({ request }) => {
  const sitemap = await request.get('/sitemap.xml');
  expect(sitemap.status()).toBe(200);
  expect(sitemap.headers()['content-type']).toContain('xml');
  const xml = await sitemap.text();
  for (const p of pages(facts)) expect(xml).toContain(`<loc>${origin}${p.path}</loc>`);

  const robots = await (await request.get('/robots.txt')).text();
  expect(robots).not.toMatch(/Disallow:\s*\S/);
  for (const bot of CRAWLERS) expect(robots).toContain(`User-agent: ${bot}\nAllow: /`);
  expect(robots).toContain(`Sitemap: ${origin}/sitemap.xml`);

  const llms = await request.get('/llms.txt');
  expect(llms.status()).toBe(200);
  expect(await llms.text()).toMatch(/^# Prompter/);

  const og = await request.get('/og.png');
  expect(og.status()).toBe(200);
  expect(og.headers()['content-type']).toBe('image/png');
});

test('no cookies are set and no third-party requests are made', async ({ page, context }) => {
  const hosts = new Set<string>();
  page.on('request', (r) => hosts.add(new URL(r.url()).host));
  for (const p of pages(facts)) await page.goto(p.path);
  expect([...hosts]).toEqual(['127.0.0.1:4517']);
  expect(await context.cookies()).toEqual([]);
});
