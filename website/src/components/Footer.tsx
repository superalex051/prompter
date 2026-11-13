import { facts, copyrightLine } from '../content/facts.ts';
import { creditLine } from '../content/claims.ts';

export function Footer() {
  return (
    <footer className="s-foot">
      <div className="s-foot-in">
        <nav aria-label="Footer">
          <ul className="s-foot-links">
            <li><a href={facts.links.rig}>The rig</a></li>
            <li><a href={facts.links.support}>Support</a></li>
            <li><a href={facts.links.privacy}>Privacy</a></li>
            <li><a href={facts.links.github}>GitHub</a></li>
          </ul>
        </nav>
        <p>{copyrightLine}</p>
        <p data-testid="credit-line">{creditLine(facts)}</p>
      </div>
    </footer>
  );
}
