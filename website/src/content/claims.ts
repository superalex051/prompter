// Lines the pages print that depend on facts. Pure functions of Facts, so tests can flip a flag
// and check every state. Keep this file erasable TypeScript (node imports it in tests).
import type { Facts } from './facts.ts';

/** "a, b and c" */
export function joinAnd(items: string[]): string {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

/** The App Store listing exists (pre-order or live). */
export function isListed(f: Facts): boolean {
  return f.storeState !== 'coming-soon';
}

/** Apple's badge shows only once the listing exists. Before that the page says "Coming soon to the App Store". */
export function showsBadge(f: Facts): boolean {
  return isListed(f);
}

/** The devices Prompter runs on, without Apple Watch (the subhead names it on its own). */
export function deviceList(f: Facts): string {
  const devices: string[] = [];
  if (f.platforms.iphone) devices.push('iPhone');
  if (f.platforms.ipad) devices.push('iPad');
  if (f.platforms.mac) devices.push('Mac');
  return joinAnd(devices);
}

export function subhead(f: Facts): string {
  const watch = f.platforms.watch ? ' Run it from your Apple Watch.' : '';
  return `A teleprompter for ${deviceList(f)}.${watch}`;
}

/** Apple's credit line. "the Apple logo" joins only when a badge shows; "Mac" only when the Mac is in the listing. */
export function creditLine(f: Facts): string {
  const marks = ['Apple'];
  if (showsBadge(f)) marks.push('the Apple logo');
  marks.push('iPhone', 'iPad');
  if (f.platforms.mac) marks.push('Mac');
  marks.push('Apple Watch');
  return `${joinAnd(marks)} are trademarks of Apple Inc., registered in the U.S. and other countries. App Store is a service mark of Apple Inc.`;
}

/** The price as printed, from facts only. */
export function priceLabel(f: Facts): string {
  return `${f.price.symbol}${f.price.amount}`;
}

export type ListItem = { text: string; soon?: boolean };

/** What Pro adds (plan decision 5). */
export function proItems(f: Facts): ListItem[] {
  const items: ListItem[] = [{ text: 'Voice-follow' }, { text: 'Apple Watch, Siri and Shortcuts as remotes' }];
  if (f.platforms.mac) items.push({ text: 'Presenting from a Mac' });
  items.push({ text: 'More than 5 scripts' });
  return items;
}

/** What stays free (plan decision 5). iCloud sync is listed as coming until it ships. */
export function freeItems(f: Facts): ListItem[] {
  return [
    { text: 'Mirroring for glass' },
    { text: 'Every speed mode: Speed, Finish in and WPM' },
    { text: 'iCloud sync', soon: !f.icloud },
  ];
}
