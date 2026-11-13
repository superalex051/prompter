import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const CREDIT =
  'Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc., registered in the U.S. and other countries. App Store is a service mark of Apple Inc.';

const PAGES = [
  { path: '/', h1: 'Read the script. Keep eye contact.' },
  { path: '/support/', h1: 'Support' },
  { path: '/privacy/', h1: 'Privacy Policy' },
  { path: '/rig/', h1: 'How a glass teleprompter rig works' },
];

async function horizontalOverflow(page: Page) {
  return page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
}

for (const p of PAGES) {
  test(`${p.path} has the shell, the credit line and no horizontal scroll`, async ({ page }) => {
    const errors: string[] = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(e.message));
    const res = await page.goto(p.path);
    expect(res?.status()).toBe(200);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(p.h1);
    const header = page.getByRole('banner');
    await expect(header.getByRole('link', { name: 'Prompter', exact: true })).toBeVisible();
    await expect(header.getByRole('link', { name: 'Support', exact: true })).toBeVisible();
    const footer = page.getByRole('contentinfo');
    for (const name of ['The rig', 'Support', 'Privacy', 'GitHub']) {
      await expect(footer.getByRole('link', { name, exact: true })).toBeVisible();
    }
    await expect(page.getByTestId('credit-line')).toHaveText(CREDIT);
    await expect(footer).toContainText('© 2026 Florida Focus Creation LLC');
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    // Every image on the page loaded.
    const broken = await page.evaluate(() =>
      [...document.images].filter((i) => i.complete && i.naturalWidth === 0).map((i) => i.src),
    );
    expect(broken).toEqual([]);
    // No script errors and no hydration mismatches.
    expect(errors).toEqual([]);
  });

  test(`${p.path} has no axe violations`, async ({ page }) => {
    await page.goto(p.path);
    const results = await new AxeBuilder({ page }).analyze();
    expect(results.violations).toEqual([]);
  });
}

test('every page fits a 320 px phone and an 820 px iPad without horizontal scroll', async ({ page }) => {
  test.skip((page.viewportSize()?.width ?? 0) > 720, 'checked once per browser, from the phone projects');
  for (const size of [{ width: 320, height: 640 }, { width: 820, height: 1180 }]) {
    await page.setViewportSize(size);
    for (const path of [...PAGES.map((p) => p.path), '/no-such-page/']) {
      await page.goto(path);
      expect(await horizontalOverflow(page), `${path} at ${size.width}`).toBeLessThanOrEqual(0);
    }
  }
});

test('unknown path returns a real 404 with the prompter line, no horizontal scroll, axe clean', async ({ page }) => {
  const res = await page.goto('/no-such-page/');
  expect(res?.status()).toBe(404);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText("This page isn't in the script.");
  await expect(page.getByRole('main').getByRole('link', { name: /Home page/ })).toHaveAttribute('href', '/');
  await expect(page.getByRole('main').getByRole('link', { name: /Support/ })).toHaveAttribute('href', '/support/');
  expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test('header: Features and The rig on wide screens, only Support on a phone', async ({ page }) => {
  await page.goto('/support/');
  const nav = page.getByRole('navigation', { name: 'Main' });
  const phone = (page.viewportSize()?.width ?? 0) <= 720;
  for (const name of ['Features', 'The rig']) {
    const link = nav.getByRole('link', { name, exact: true });
    if (phone) await expect(link).toBeHidden();
    else await expect(link).toBeVisible();
  }
  await expect(nav.getByRole('link', { name: 'Support', exact: true })).toHaveAttribute('aria-current', 'page');
});

test('home: anchors the app links to, store line, Pro band and source line', async ({ page }) => {
  await page.goto('/');
  for (const id of ['features', 'apple-watch', 'mac', 'rig', 'pro']) {
    await expect(page.locator(`#${id}`)).toHaveCount(1);
  }
  await expect(page.locator('#apple-watch h3')).toHaveText('Apple Watch remote');
  await expect(page.locator('#mac h3')).toHaveText('Present from a Mac');
  await expect(page.getByText('Coming soon to the App Store', { exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: /How the rig works/ }).first()).toHaveAttribute('href', '/rig/');
  const pro = page.locator('#pro');
  await expect(pro.getByRole('heading', { level: 2 })).toContainText('Pro is $9.99 once.');
  for (const item of ['Voice-follow', 'Apple Watch, Siri and Shortcuts as remotes', 'Presenting from a Mac', 'More than 5 scripts']) {
    await expect(pro.getByText(item, { exact: true })).toBeVisible();
  }
  await expect(pro.getByRole('listitem').filter({ hasText: 'iCloud sync' })).toContainText('Coming soon');
  await expect(page.locator('#rig')).toContainText('Printable files for the rig are coming later.');
  await expect(page.getByRole('link', { name: /Prompter on GitHub/ })).toHaveAttribute(
    'href',
    'https://github.com/superalex051/prompter',
  );
  // The iCloud tile is marked as coming.
  await expect(page.locator('.s-tile').filter({ hasText: 'Your scripts, everywhere' })).toContainText('Coming soon');
  // No Apple device frames before launch: only the plain screenshots.
  const srcs = await page.evaluate(() => [...document.images].map((i) => new URL(i.src).pathname));
  expect(srcs.every((s) => s.startsWith('/shots/m'))).toBe(true);
});

test('support: the question list links to every answer', async ({ page }) => {
  await page.goto('/support/');
  const index = page.locator('.qidx a');
  const count = await index.count();
  expect(count).toBe(10);
  for (let i = 0; i < count; i++) {
    const href = await index.nth(i).getAttribute('href');
    await expect(page.locator(href ?? '#missing')).toHaveCount(1);
  }
  await expect(page.getByRole('navigation', { name: 'On this page' })).toBeVisible();
  await expect(page.locator('.slot')).toHaveCount(1);
});
