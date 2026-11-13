import { test } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

// Full-page screenshots of every page for a person to look at. Runs only with SHOTS=1 (npm run shots).
// They land in the repo's git-ignored qa/output/website/.
const out = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'qa', 'output', 'website');

const PAGES = [
  { name: 'home', path: '/' },
  { name: 'support', path: '/support/' },
  { name: 'privacy', path: '/privacy/' },
  { name: 'rig', path: '/rig/' },
  { name: '404', path: '/no-such-page/' },
];

test.skip(!process.env.SHOTS, 'screenshots run only with SHOTS=1');

for (const p of PAGES) {
  test(`screenshot ${p.name}`, async ({ page }, info) => {
    await page.goto(p.path);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForLoadState('load');
    await page.screenshot({
      path: join(out, `${p.name}-${info.project.name}.png`),
      fullPage: true,
      animations: 'disabled',
    });
  });
}
