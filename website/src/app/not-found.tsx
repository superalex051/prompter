import type { Metadata } from 'next';
import { facts } from '../content/facts.ts';

export const metadata: Metadata = {
  title: 'Page not found',
};

// Set as a prompter line between the reading-line chevrons. The host sends a real 404 status.
export default function NotFound() {
  return (
    <div className="s-404">
      <div className="s-404-line">
        <svg className="l" viewBox="0 0 16 20" aria-hidden="true">
          <path d="M0 0L16 10L0 20Z" />
        </svg>
        <h1>
          This page isn&apos;t <br />
          in the script.
        </h1>
        <svg className="r" viewBox="0 0 16 20" aria-hidden="true">
          <path d="M16 0L0 10L16 20Z" />
        </svg>
      </div>
      <p>The link may be old or mistyped.</p>
      <div className="s-404-links">
        <a href={facts.links.home}>
          Home page<span className="chev" aria-hidden="true">›</span>
        </a>
        <a href={facts.links.support}>
          Support<span className="chev" aria-hidden="true">›</span>
        </a>
      </div>
    </div>
  );
}
