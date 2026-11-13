# Prompter website

The public site for Prompter. It lives in this repo under `website/`, is a static export, and Vercel builds it from
GitHub (Root Directory `website`).

## Layout
- `src/app/`: pages (Next.js App Router, static export).
- `src/components/`: shared shell (header, footer).
- `src/content/facts.ts`: every product fact the site states. `scripts/check-app-facts.mjs` checks it against the app source.
- `src/content/device-frames.ts`: URLs of Apple device images on Vercel Blob. The images are never committed.
- `tests/`: unit tests (`node:test`). `e2e/`: Playwright tests.
- `scripts/serve-static.mjs`: static server for the exported `out/` folder.

## Commands
Run from `website/`. Every build and Playwright run goes through the heavy-task lock:

```bash
npm install                                          # not heavy
../scripts/heavy.sh --task <ID> -- npm run check     # unit tests, facts check, build, Playwright, npm audit
../scripts/heavy.sh --task <ID> -- npm run build
../scripts/heavy.sh --task <ID> -- npx playwright test
```

## Rules that apply everywhere
- Checks use the static server on `127.0.0.1:4517` only. Never use the default dev ports and never run `next dev` in checks.
- Pin exact versions (`--save-exact`). Run `npm audit` whenever dependencies change.
- No analytics, no trackers, no third-party scripts.
- Apple product images: never commit them. They come from Vercel Blob URLs in `src/content/device-frames.ts`.
  Keep Apple's image rules and the trademark credit line in the footer: "Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc."
- All site text, images and design are all rights reserved (see `NOTICE` at the repo root). The code license covers code only.
- Product claims (price, platforms, features, iCloud, Pro) come from `facts.ts`, not from page text.
- The price in `facts.ts` is pending StoreKit until the app sells it.

## Brand
Dark, system font, amber accent. The approved direction is "page 5": black paper, white ink, amber `oklch(80% 0.165 72)`.

## Working style
- Plain copy, short sentences, no em dashes or en dashes, no promo words.
- Real pages wait for the approved mockups. Until then the home page is a placeholder.
- Phone width (390) and desktop (1440) must both work with no horizontal scroll.

## Compact instructions
Keep: the rules above, the commands, and which files hold facts. Drop: build logs and install output.

## Commit trailers
End every commit message with the attribution lines the session gives.
