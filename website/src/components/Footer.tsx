import { facts, creditLine, copyrightLine } from '../content/facts.ts';

const link = 'text-muted underline-offset-4 hover:text-ink hover:underline';

export function Footer() {
  return (
    <footer className="border-t border-hair">
      <div className="mx-auto max-w-5xl px-5 py-10 text-sm text-muted">
        <ul className="flex flex-wrap gap-x-6 gap-y-2">
          <li><a className={link} href={facts.links.privacy}>Privacy</a></li>
          <li><a className={link} href={facts.links.support}>Support</a></li>
          <li><a className={link} href={facts.links.github}>GitHub</a></li>
        </ul>
        <p className="mt-6">{copyrightLine}</p>
        <p className="mt-2" data-testid="credit-line">{creditLine}</p>
      </div>
    </footer>
  );
}
