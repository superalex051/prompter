// A small content model for the text pages (support, privacy, rig).
// Text uses three bits of inline markup:
//   [label](href)      a link
//   [Owner: ...]       a slot the owner fills before the site goes live (shown on the page, styled as a slot)
//   bare https:// URLs and email addresses become links on their own.
// Every block can carry `when`, a test on facts; the block shows only when it returns true.
import type { Facts } from './facts.ts';

export type When = (f: Facts) => boolean;

export type Item = { text: string; when?: When; items?: Item[] };

export type Block =
  | { kind: 'h2'; id: string; text: string; when?: When }
  | { kind: 'h3'; id: string; text: string; when?: When }
  | { kind: 'p'; text: string; when?: When; panel?: boolean }
  | { kind: 'ul'; items: Item[]; when?: When; panel?: boolean; ordered?: boolean }
  | { kind: 'questions'; when?: When }
  // A picture the page draws (rig page). `text` is shown with it, for example a slot for a photo.
  | { kind: 'figure'; name: 'diagram' | 'photo' | 'mirror-pair' | 'ghost'; text?: string; when?: When };

export function shown<T extends { when?: When }>(f: Facts, list: T[]): T[] {
  return list.filter((b) => !b.when || b.when(f));
}

export type Token =
  | { type: 'text'; value: string }
  | { type: 'link'; value: string; href: string }
  | { type: 'slot'; value: string };

const INLINE =
  /\[([^\]]+)\]\(([^)\s]+)\)|(\[Owner: [^\]]+\])|(https:\/\/[^\s)]*[^\s).,;:])|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,})/g;

export function tokenize(text: string): Token[] {
  const out: Token[] = [];
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    const at = m.index ?? 0;
    if (at > last) out.push({ type: 'text', value: text.slice(last, at) });
    if (m[1] !== undefined) out.push({ type: 'link', value: m[1], href: m[2] });
    else if (m[3] !== undefined) out.push({ type: 'slot', value: m[3] });
    else if (m[4] !== undefined) out.push({ type: 'link', value: m[4], href: m[4] });
    else if (m[5] !== undefined) out.push({ type: 'link', value: m[5], href: `mailto:${m[5]}` });
    last = at + m[0].length;
  }
  if (last < text.length) out.push({ type: 'text', value: text.slice(last) });
  return out;
}

/** The words a reader sees, with the markup taken out. */
export function plain(text: string): string {
  return tokenize(text).map((t) => t.value).join('');
}

/** Every slot in the blocks that show for these facts. */
export function slotsIn(f: Facts, blocks: Block[]): string[] {
  const texts: string[] = [];
  const walk = (items: Item[]) => {
    for (const i of shown(f, items)) {
      texts.push(i.text);
      if (i.items) walk(i.items);
    }
  };
  for (const b of shown(f, blocks)) {
    if (b.kind === 'ul') walk(b.items);
    else if (b.kind === 'figure') { if (b.text) texts.push(b.text); }
    else if (b.kind !== 'questions') texts.push(b.text);
  }
  return texts.flatMap((t) => tokenize(t).filter((k) => k.type === 'slot').map((k) => k.value));
}

/** All the text that shows for these facts, one line per block or list item, markup removed. */
export function visibleText(f: Facts, blocks: Block[]): string[] {
  const lines: string[] = [];
  const walk = (items: Item[]) => {
    for (const i of shown(f, items)) {
      lines.push(plain(i.text));
      if (i.items) walk(i.items);
    }
  };
  for (const b of shown(f, blocks)) {
    if (b.kind === 'ul') walk(b.items);
    else if (b.kind === 'figure') { if (b.text) lines.push(plain(b.text)); }
    else if (b.kind === 'questions') {
      for (const q of shown(f, blocks)) if (q.kind === 'h3') lines.push(q.text);
    } else lines.push(plain(b.text));
  }
  return lines;
}
