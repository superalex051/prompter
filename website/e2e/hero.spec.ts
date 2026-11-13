import { test, expect, type Page } from '@playwright/test';

// The live hero on the home page: Mirror it flips the screen only; Pause stops the text and the clock;
// with Reduce Motion it starts paused.

const roll = (page: Page) => page.getByTestId('hero-screen').locator('.proll');

async function rollState(page: Page) {
  return roll(page).evaluate((el) => {
    const cs = getComputedStyle(el);
    return { play: cs.animationPlayState, transform: cs.transform };
  });
}

// Vertical offset of the rolling text, in px (from the computed transform matrix).
const offsetY = (transform: string) => (transform === 'none' ? 0 : Number(transform.split(',')[5]?.replace(')', '')));

// How far the text moves in `ms`. Running, it rolls about 25 to 70 px a second, depending on width.
async function movedIn(page: Page, ms: number) {
  const a = offsetY((await rollState(page)).transform);
  await page.waitForTimeout(ms);
  const b = offsetY((await rollState(page)).transform);
  return Math.abs(b - a);
}

// After a pause, Chromium can move a compositor animation by a frame while it syncs; let that settle.
const settle = (page: Page) => page.waitForTimeout(300);

test('the text rolls, and Pause stops it and the clock; Play starts it again', async ({ page }) => {
  await page.goto('/');
  const hero = page.getByTestId('hero');
  await hero.scrollIntoViewIfNeeded();
  const pause = hero.getByRole('button', { name: 'Pause' });
  await expect(pause).toBeVisible();

  expect(await movedIn(page, 700)).toBeGreaterThan(5);
  expect((await rollState(page)).play).toBe('running');

  await pause.click();
  await expect(hero.getByRole('button', { name: 'Play' })).toBeVisible();
  expect((await rollState(page)).play).toBe('paused');
  await settle(page);
  expect(await movedIn(page, 700)).toBeLessThan(1);
  await expect(page.getByTestId('hero-screen').locator('.pword')).toHaveText('Paused');
  const clock = page.getByTestId('hero-screen').locator('.ptime');
  const before = await clock.textContent();
  await page.waitForTimeout(1300);
  expect(await clock.textContent()).toBe(before);

  await hero.getByRole('button', { name: 'Play' }).click();
  await expect(hero.getByRole('button', { name: 'Pause' })).toBeVisible();
  expect((await rollState(page)).play).toBe('running');
  expect(await movedIn(page, 700)).toBeGreaterThan(5);
});

test('Mirror it flips the screen only, and says so as a toggle', async ({ page }) => {
  await page.goto('/');
  const hero = page.getByTestId('hero');
  await hero.scrollIntoViewIfNeeded();
  const mirror = hero.getByRole('button', { name: 'Mirror it' });
  await expect(mirror).toHaveAttribute('aria-pressed', 'false');

  const flip = page.getByTestId('hero-screen').locator('.pflip');
  const caption = hero.locator('figcaption');
  const captionBox = await caption.boundingBox();
  const screenBox = await page.getByTestId('hero-screen').boundingBox();
  expect(await flip.evaluate((el) => getComputedStyle(el).transform)).toBe('none');

  await mirror.click();
  await expect(mirror).toHaveAttribute('aria-pressed', 'true');
  await expect(mirror).toHaveText('Mirror it');
  await expect.poll(() => flip.evaluate((el) => getComputedStyle(el).transform)).toBe('matrix(-1, 0, 0, 1, 0, 0)');

  // The screen frame, the caption and the page around them never flip or move.
  for (const el of [hero, page.getByTestId('hero-screen'), caption, page.locator('body')]) {
    expect(await el.evaluate((e) => getComputedStyle(e).transform)).toBe('none');
  }
  expect(await caption.boundingBox()).toEqual(captionBox);
  expect(await page.getByTestId('hero-screen').boundingBox()).toEqual(screenBox);

  await mirror.click();
  await expect(mirror).toHaveAttribute('aria-pressed', 'false');
  await expect.poll(() => flip.evaluate((el) => getComputedStyle(el).transform)).toBe('none');
});

test.describe('with Reduce Motion on', () => {
  test.use({ reducedMotion: 'reduce' });

  test('the hero starts paused and rolls only after Play', async ({ page }) => {
    await page.goto('/');
    const hero = page.getByTestId('hero');
    await hero.scrollIntoViewIfNeeded();
    await expect(hero.getByRole('button', { name: 'Play' })).toBeVisible();
    expect((await rollState(page)).play).toBe('paused');
    await settle(page);
    expect(await movedIn(page, 700)).toBeLessThan(1);

    await hero.getByRole('button', { name: 'Play' }).click();
    await expect(hero.getByRole('button', { name: 'Pause' })).toBeVisible();
    expect((await rollState(page)).play).toBe('running');
    expect(await movedIn(page, 700)).toBeGreaterThan(5);
  });
});
