import { facts } from '../content/facts.ts';
import { subhead, priceLabel, proItems, freeItems, isListed, type ListItem } from '../content/claims.ts';
import { rigFilesLine } from '../content/rig.ts';
import { Hero } from '../components/Hero';
import { JsonLd } from '../components/JsonLd';
import { applicationLd, organizationLd } from '../content/seo.ts';
import { pageMetadata } from '../lib/meta.ts';

export const metadata = pageMetadata('home');
import { RigDiagram } from '../components/RigDiagram';

// Plain screenshots until the app is live (no Apple device frames before launch).
// The Mac tile has no screenshot until the Mac retake; it shows the Presenter view's keys instead.

const MAC_KEYS: { keys: { label: string; spoken?: string }[]; action: string }[] = [
  { keys: [{ label: 'Space' }], action: 'Start or pause' },
  { keys: [{ label: '↑', spoken: 'Up arrow' }], action: 'Back a line' },
  { keys: [{ label: '↓', spoken: 'Down arrow' }], action: 'Forward a line' },
  { keys: [{ label: '−', spoken: 'Minus' }, { label: '+', spoken: 'Plus' }], action: 'Slower, faster' },
  { keys: [{ label: '0' }], action: 'Back to top' },
];

function Chev() {
  return <span className="chev" aria-hidden="true">›</span>;
}

function Soon() {
  return <span className="s-tag">Coming soon</span>;
}

function PlanList({ items }: { items: ListItem[] }) {
  return (
    <ul>
      {items.map((item) => (
        <li key={item.text}>
          {item.text}
          {item.soon ? <Soon /> : null}
        </li>
      ))}
    </ul>
  );
}

export default function Home() {
  const mac = facts.platforms.mac;
  const listed = isListed(facts);
  const price = priceLabel(facts);

  return (
    <>
      <JsonLd data={organizationLd(facts)} />
      <JsonLd data={applicationLd(facts)} />
      <section className="s-hero" aria-labelledby="hero-title">
        <h1 className="s-h1" id="hero-title">
          Read the script. <br />
          Keep eye contact.
        </h1>
        <p className="s-sub">{subhead(facts)}</p>
        <div className="s-cta">
          {listed ? null : <p className="s-soon">Coming soon to the App Store</p>}
          <a className="s-more" href={facts.links.rig}>
            How the rig works<Chev />
          </a>
        </div>
        <Hero />
      </section>

      <section className="s-feat" id="features" aria-labelledby="features-title">
        <h2 className="s-h2" id="features-title">Start it from wherever you stand.</h2>
        <div className="s-grid">
          <article className="s-tile" id="apple-watch">
            <h3>Apple Watch remote</h3>
            <p>Start, pause and change speed from your wrist. A countdown gives you time to step back into frame.</p>
            <div className="s-shot-watch">
              <img
                src="/shots/m3-watch-playing.png"
                width={368}
                height={448}
                alt="Prompter on Apple Watch while a script plays: time left, a Pause button and speed controls"
              />
            </div>
          </article>

          <article className="s-tile">
            <h3>Voice-follow</h3>
            <p>It listens as you talk and scrolls with you. Stop talking and it waits. Speech is recognized on your device.</p>
            <div className="s-shot-land">
              <img
                src="/shots/m4-voice-following-1.png"
                width={1400}
                height={644}
                alt="Prompter following the reader's voice, with the text mirrored for glass"
              />
            </div>
          </article>

          {mac ? (
            <article className="s-tile" id="mac">
              <h3>Present from a Mac</h3>
              <p>Put the script on a second screen and drive it from your MacBook keyboard.</p>
              <div className="s-keys">
                <p className="s-keys-label">Keys</p>
                <dl>
                  {MAC_KEYS.map((row) => (
                    <div key={row.action} style={{ display: 'contents' }}>
                      <dt>
                        {row.keys.map((k) => (
                          <kbd key={k.label}>
                            {k.spoken ? (
                              <>
                                <span aria-hidden="true">{k.label}</span>
                                <span className="sr-only">{k.spoken}</span>
                              </>
                            ) : (
                              k.label
                            )}
                          </kbd>
                        ))}
                      </dt>
                      <dd>{row.action}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            </article>
          ) : null}

          <article className={mac ? 's-tile' : 's-tile span'}>
            <div className="s-tile-text">
              {facts.icloud ? null : <p className="s-tag">Coming soon</p>}
              <h3>Your scripts, everywhere</h3>
              <p>Scripts sync through your own iCloud. We never see them.</p>
            </div>
            <div className="s-shot-port">
              <img
                src="/shots/m1-library.png"
                width={644}
                height={1400}
                alt="The script library on iPhone, with a Prompt button beside each script"
              />
            </div>
          </article>
        </div>
      </section>

      <section className="s-rig" id="rig" aria-labelledby="rig-title">
        <h2 className="s-h2" id="rig-title">Built for a glass rig.</h2>
        <p className="s-lead">
          Your iPhone lies flat under a sheet of glass in front of the lens. You read the reflection, and the camera
          films you through the glass.
        </p>
        <p className="s-note">{rigFilesLine}</p>
        <a className="s-more" href={facts.links.rig}>
          How the rig works<Chev />
        </a>
        <RigDiagram />
      </section>

      <section className="s-pro" id="pro" aria-labelledby="pro-title">
        <h2 id="pro-title">
          No subscription.
          <br />
          <span className="amb">Pro is {price} once.</span>
        </h2>
        <p>
          {listed ? 'Prompter is free to download' : 'Prompter will be free to download'}, with no account. Pro is one
          payment that you keep.
        </p>
        <div className="s-plans">
          <div className="s-plan">
            <h3>Free</h3>
            <PlanList items={freeItems(facts)} />
          </div>
          <div className="s-plan pro">
            <h3>
              Pro <span className="price">{price} once</span>
            </h3>
            <PlanList items={proItems(facts)} />
          </div>
        </div>
        <p className="s-fine">US price. Apple sets the price in other countries.</p>
      </section>

      <section className="s-src" aria-label="Source code">
        <p>The source is public. Build it yourself for free.</p>
        <a href={facts.links.github}>
          Prompter on GitHub<Chev />
        </a>
      </section>
    </>
  );
}
