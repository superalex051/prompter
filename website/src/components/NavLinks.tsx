'use client';

import { usePathname } from 'next/navigation';
import { facts } from '../content/facts.ts';

// Before launch the header has no store button (it would lead nowhere). On a phone only Support shows.
// The pre-order and download buttons come with the App Store listing.
const LINKS = [
  { label: 'Features', href: facts.links.features, wide: true },
  { label: 'The rig', href: facts.links.rig, wide: true },
  { label: 'Support', href: facts.links.support, wide: false },
];

const trim = (p: string) => (p.length > 1 ? p.replace(/\/+$/, '') : p);

export function NavLinks() {
  const path = trim(usePathname() ?? '/');
  return (
    <ul className="s-links">
      {LINKS.map((l) => (
        <li key={l.href} className={l.wide ? 'wide' : undefined}>
          <a href={l.href} aria-current={trim(l.href) === path ? 'page' : undefined}>
            {l.label}
          </a>
        </li>
      ))}
    </ul>
  );
}
