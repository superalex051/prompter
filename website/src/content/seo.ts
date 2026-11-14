// Search and answer-engine text: per-page titles and descriptions, JSON-LD, llms.txt, robots.txt, the sitemap.
// Pure functions of Facts so tests can flip a flag and check every state. Keep this file erasable TypeScript.
import type { Facts } from './facts.ts';
import type { Block } from './doc.ts';
import { shown, plain } from './doc.ts';
import { deviceList, isListed, priceLabel, proItems, freeItems } from './claims.ts';

export const OG_IMAGE = { path: '/og.png', width: 1200, height: 630 };

/** Crawlers named in robots.txt. Every one is allowed. */
export const CRAWLERS = [
  'Googlebot', 'Bingbot', 'Applebot', 'Applebot-Extended', 'DuckDuckBot',
  'GPTBot', 'OAI-SearchBot', 'ChatGPT-User', 'ClaudeBot', 'Claude-SearchBot', 'Claude-User',
  'anthropic-ai', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'CCBot', 'Bytespider',
];

export type PageId = 'home' | 'support' | 'privacy' | 'rig';

export type PageMeta = {
  id: PageId;
  path: string;
  /** The full <title>. */
  title: string;
  description: string;
  /** Name shown in breadcrumbs (not for home). */
  crumb?: string;
};

export function siteUrl(f: Facts): string {
  return `https://${f.domain}`;
}

export function absoluteUrl(f: Facts, path: string): string {
  return `${siteUrl(f)}${path}`;
}

const soon = (f: Facts) => (isListed(f) ? '' : ' Coming soon to the App Store.');

/** Every indexable page. The 404 is not here. */
export function pages(f: Facts): PageMeta[] {
  const devices = deviceList(f);
  const watch = f.platforms.watch ? ' with an Apple Watch remote' : '';
  return [
    {
      id: 'home',
      path: f.links.home,
      title: `${f.name}: a teleprompter for ${devices}`,
      description: `${f.name} is a teleprompter for ${devices}${watch}. Mirrors text for a glass rig. No subscription.${soon(f)}`,
    },
    {
      id: 'rig',
      path: f.links.rig,
      title: `How a glass teleprompter rig works · ${f.name}`,
      description: `How a beam-splitter teleprompter rig works with an iPhone: the glass, the mirrored text, the double image on acrylic, and the ${f.name} defaults that cope with it.`,
      crumb: 'The rig',
    },
    {
      id: 'support',
      path: f.links.support,
      title: `Support and FAQ · ${f.name}`,
      description: `Contact, requirements and answers about mirroring text for glass, using Apple Watch as a remote${f.platforms.mac ? ', presenting from a Mac' : ''} and Voice-follow.`,
      crumb: 'Support',
    },
    {
      id: 'privacy',
      path: f.links.privacy,
      title: `Privacy policy · ${f.name}`,
      description: `The ${f.name} app collects no data and has no accounts. What stays on your device, and what this website and Apple see.`,
      crumb: 'Privacy',
    },
  ];
}

export function pageMeta(f: Facts, id: PageId): PageMeta {
  const p = pages(f).find((x) => x.id === id);
  if (!p) throw new Error(`unknown page ${id}`);
  return p;
}

type Entry = { question: string; answer: string };

/** Questions and answers as the support page shows them: each h3, then the paragraphs and list items up to the next heading. */
export function faqEntries(f: Facts, blocks: Block[]): Entry[] {
  const out: Entry[] = [];
  let question: string | null = null;
  let parts: string[] = [];
  const flush = () => {
    if (question !== null && parts.length) out.push({ question, answer: parts.join(' ') });
    question = null;
    parts = [];
  };
  for (const b of shown(f, blocks)) {
    if (b.kind === 'h3') {
      flush();
      question = b.text;
    } else if (b.kind === 'h2') {
      flush();
    } else if (question !== null && b.kind === 'p') {
      parts.push(plain(b.text));
    } else if (question !== null && b.kind === 'ul') {
      for (const i of shown(f, b.items)) parts.push(plain(i.text));
    }
  }
  flush();
  return out;
}

const orgId = (f: Facts) => `${siteUrl(f)}/#organization`;
const appId = (f: Facts) => `${siteUrl(f)}/#app`;

export function organizationLd(f: Facts) {
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    '@id': orgId(f),
    name: f.owner,
    url: siteUrl(f),
    sameAs: [f.links.github],
  };
}

export function applicationLd(f: Facts) {
  const os = ['iOS'];
  if (f.platforms.ipad) os.push('iPadOS');
  if (f.platforms.mac) os.push('macOS');
  if (f.platforms.watch) os.push('watchOS');
  const offer: Record<string, string> = { '@type': 'Offer', price: '0', priceCurrency: f.price.currency };
  if (isListed(f)) offer.availability = 'https://schema.org/InStock';
  return {
    '@context': 'https://schema.org',
    '@type': 'MobileApplication',
    '@id': appId(f),
    name: f.name,
    url: siteUrl(f),
    description: `A teleprompter for ${deviceList(f)}. It mirrors text for a glass rig, follows your voice and can be run from an Apple Watch.`,
    applicationCategory: 'MultimediaApplication',
    operatingSystem: os.join(', '),
    offers: offer,
    publisher: { '@id': orgId(f) },
    image: absoluteUrl(f, OG_IMAGE.path),
  };
}

export function faqLd(f: Facts, blocks: Block[]) {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: faqEntries(f, blocks).map((e) => ({
      '@type': 'Question',
      name: e.question,
      acceptedAnswer: { '@type': 'Answer', text: e.answer },
    })),
  };
}

export function breadcrumbLd(f: Facts, id: PageId) {
  const home = pageMeta(f, 'home');
  const page = pageMeta(f, id);
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: [
      { '@type': 'ListItem', position: 1, name: f.name, item: absoluteUrl(f, home.path) },
      { '@type': 'ListItem', position: 2, name: page.crumb ?? page.title, item: absoluteUrl(f, page.path) },
    ],
  };
}

/** llms.txt: plain facts about the product, with links. Follows the llms.txt layout (title, summary, link lists). */
export function llmsTxt(f: Facts): string {
  const listed = isListed(f);
  const pro = proItems(f).map((i) => i.text).join('; ');
  const free = freeItems(f).map((i) => (i.soon ? `${i.text} (not available yet)` : i.text)).join('; ');
  const lines = [
    `# ${f.name}`,
    '',
    `> ${f.name} is a teleprompter app for ${deviceList(f)}${f.platforms.watch ? ', with an Apple Watch remote' : ''}. It mirrors the script for a glass (beam-splitter) rig and can follow the reader's voice. It has no accounts, no subscription and no analytics. It is published by ${f.owner}.`,
    '',
    '## Facts',
    '',
    `- Status: ${listed ? 'on the App Store.' : 'not on the App Store yet. The source code is public and can be built for free.'}`,
    `- Devices: ${deviceList(f)}${f.platforms.watch ? ' and Apple Watch (remote)' : ''}. Needs iOS 26${f.platforms.ipad ? ', iPadOS 26' : ''}${f.platforms.mac ? ' or macOS 26' : ''} or later.`,
    `- Price: the app is a free download. Prompter Pro is one payment of ${priceLabel(f)} (US price), not a subscription.`,
    `- Free: ${free}.`,
    `- Pro adds: ${pro}.`,
    '- Privacy: the app collects no data. Voice-follow recognizes speech on the device.',
    '- License: the source code is GNU GPL version 3. The website text, images and design are all rights reserved.',
    '',
    '## Pages',
    '',
    ...pages(f).map((p) => `- [${p.crumb ?? 'Home'}](${absoluteUrl(f, p.path)}): ${p.description}`),
    '',
    '## Source and contact',
    '',
    `- [Source code on GitHub](${f.links.github})`,
    `- [Report an issue](${f.links.githubIssues})`,
    `- Email: ${f.supportEmail}`,
    '',
  ];
  return lines.join('\n');
}

export function robotsTxt(f: Facts): string {
  const groups = ['*', ...CRAWLERS].map((ua) => `User-agent: ${ua}\nAllow: /`);
  return `${groups.join('\n\n')}\n\nSitemap: ${absoluteUrl(f, '/sitemap.xml')}\n`;
}

export function sitemapXml(f: Facts): string {
  const urls = pages(f).map((p) => `  <url><loc>${absoluteUrl(f, p.path)}</loc></url>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join('\n')}\n</urlset>\n`;
}
