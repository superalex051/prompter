import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const CREDIT = 'Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc.';

test('home page has the shell, the credit line and no horizontal scroll', async ({ page }) => {
  const res = await page.goto('/');
  expect(res?.status()).toBe(200);
  await expect(page.getByRole('link', { name: 'Prompter' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Privacy' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Support' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'GitHub' })).toBeVisible();
  await expect(page.getByTestId('credit-line')).toHaveText(CREDIT);
  await expect(page.locator('footer')).toContainText('2026 Florida Focus Creation LLC');
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});

test('home page has no axe violations', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test('unknown path returns a real 404 without horizontal scroll', async ({ page }) => {
  const res = await page.goto('/no-such-page/');
  expect(res?.status()).toBe(404);
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
