# Prompter website

The public site for Prompter. It lives in this repo under `website/`, is a static export, and Vercel builds it from
GitHub (Root Directory `website`).

## Layout
- `src/app/`: pages (Next.js App Router, static export): home, `support/`, `privacy/`, `rig/`, and `not-found.tsx` (the 404).
- `src/components/`: header, footer, the live hero (`Hero.tsx`, `PrompterScreen.tsx`), the rig drawing, and `DocPage.tsx`
  (one text column with an "On this page" list).
- `src/content/facts.ts`: every product fact the site states, plus the flags (`storeState`, `icloud`, `platforms.mac`,
  `firstRunQuestion`). `scripts/check-app-facts.mjs` checks it against the app source.
- `src/content/claims.ts`: lines that depend on facts (subhead, credit line, price, Pro and free lists).
- `src/content/support.ts`, `privacy.ts`, `rig.ts`: page text as data. Each block can carry `when`, a test on facts.
  Inline markup: `[label](href)`, bare URLs and emails become links, `[Owner: ...]` is a slot the owner fills.
- `src/content/seo.ts`: per-page titles and descriptions, JSON-LD (Organization, MobileApplication, FAQPage built from the
  support text, BreadcrumbList), `llms.txt`, `robots.txt` and `sitemap.xml` text. `src/lib/meta.ts` turns it into page
  metadata (canonical, Open Graph, Twitter). New page: add it to `pages()` in `seo.ts` (a test checks the sitemap against `src/app`).
- `public/og.png`: the 1200x630 social card, made by `scripts/make-og.mjs` (run it through heavy.sh) from our own screenshot.
- `src/content/device-frames.ts`: URLs of Apple device images on Vercel Blob. The images are never committed.
- `public/shots/`: the plain app screenshots used before launch.
- `tests/`: unit tests (`node:test`). `e2e/`: Playwright tests (`screenshots.spec.ts` runs only with `SHOTS=1`).
- `scripts/serve-static.mjs`: static server for the exported `out/` folder.

## Commands
Run from `website/`. Every build and Playwright run goes through the heavy-task lock:

```bash
npm install                                          # not heavy
../scripts/heavy.sh --task <ID> -- npm run check     # unit tests, facts check, build, Playwright, npm audit
../scripts/heavy.sh --task <ID> -- npm run build
../scripts/heavy.sh --task <ID> -- npx playwright test
../scripts/heavy.sh --task <ID> -- npm run shots    # full-page screenshots into ../qa/output/website/
npm run dev                                          # the owner's dev server on port 4519. Agents never start it.
```

## Rules that apply everywhere
- Checks use the static server on `127.0.0.1:4517` only. Never use the default dev ports and never run `next dev` in checks.
- Pin exact versions (`--save-exact`). Run `npm audit` whenever dependencies change.
- No analytics, no trackers, no third-party scripts.
- Apple product images: never commit them. They come from Vercel Blob URLs in `src/content/device-frames.ts`.
  Keep Apple's image rules and the trademark credit line in the footer (built by `creditLine` in `claims.ts`).
  Before launch: no Apple device frames, no badge, "Coming soon to the App Store" as plain text.
- All site text, images and design are all rights reserved (see `NOTICE` at the repo root). The code license covers code only.
- Product claims (price, platforms, features, iCloud, Pro) come from `facts.ts`, not from page text. A test fails if a
  price is typed anywhere else.
- The price in `facts.ts` is pending StoreKit until the app sells it.
- Support and privacy text comes from the reviewed copy. Keep its wording; change it there first.
- Slots read `[Owner: ...]`. Never put a personal name, the company's address or phone in this repo.
- Production builds (`VERCEL_ENV=production`) refuse unfilled owner slots (`scripts/check-owner-slots.mjs`); preview and local builds show them.

## Brand
Dark, system font, amber accent. The approved direction is "page 5": black paper, white ink, amber `oklch(80% 0.165 72)`.

## Working style
- Plain copy, short sentences, no em dashes or en dashes, no promo words.
- Pages follow the approved WEB-1 mockup. A new customer-facing page or flow gets a mockup first.
- Phone width (390) and desktop (1440) must both work with no horizontal scroll.

## Compact instructions
Keep: the rules above, the commands, and which files hold facts. Drop: build logs and install output.

## Commit trailers
End every commit message with the attribution lines the session gives.
