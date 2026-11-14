// Makes public/og.png (1200x630) from our own app screenshot and the wordmark. No Apple device images.
// Run through the heavy lock: ../scripts/heavy.sh --task WEB-SEO -- node scripts/make-og.mjs
import { chromium } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { facts } from '../src/content/facts.ts';
import { deviceList } from '../src/content/claims.ts';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const shot = readFileSync(join(site, 'public/shots/m2-playing-mirrored.png')).toString('base64');

const html = `<!doctype html><meta charset="utf-8"><style>
  * { box-sizing: border-box; margin: 0; }
  body { width: 1200px; height: 630px; background: #000; color: #fff; overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; position: relative; }
  .word { position: absolute; left: 72px; top: 64px; font-size: 40px; font-weight: 700; letter-spacing: -0.01em; color: #f5b83d; }
  h1 { position: absolute; left: 72px; top: 190px; width: 440px; font-size: 64px; line-height: 1.08; font-weight: 800; letter-spacing: -0.02em; }
  p { position: absolute; left: 72px; bottom: 64px; width: 460px; font-size: 24px; line-height: 1.35; color: #c9c9cc; }
  .shot { position: absolute; right: 56px; top: 132px; width: 600px; height: 366px; border-radius: 22px; overflow: hidden;
    border: 2px solid #3a3a3d; background: #111; }
  .shot img { width: 100%; height: 100%; object-fit: cover; display: block; }
</style>
<div class="word">Prompter</div>
<h1>Read the script. Keep eye contact.</h1>
<p>A teleprompter for ${deviceList(facts)}.</p>
<div class="shot"><img src="data:image/png;base64,${shot}"></div>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.setContent(html);
const png = await page.screenshot({ type: 'png' });
writeFileSync(join(site, 'public/og.png'), png);
await browser.close();
console.log('wrote public/og.png', png.length, 'bytes');
