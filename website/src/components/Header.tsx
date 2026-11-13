import { facts } from '../content/facts.ts';
import { NavLinks } from './NavLinks';

export function Header() {
  return (
    <header className="s-nav">
      <div className="s-nav-in">
        <a className="s-word" href={facts.links.home}>
          {facts.name}
        </a>
        <nav aria-label="Main">
          <NavLinks />
        </nav>
      </div>
    </header>
  );
}
