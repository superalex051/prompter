import { Fragment, type ReactNode } from 'react';
import type { Block, Item } from '../content/doc.ts';
import { shown } from '../content/doc.ts';
import { facts } from '../content/facts.ts';
import { Inline } from './Inline';

type Props = {
  title: string;
  dek?: string;
  effective?: string;
  blocks: Block[];
  /** Show the "On this page" list (support, privacy). */
  toc?: boolean;
  /** Pictures for `figure` blocks, by name. */
  figures?: Record<string, ReactNode>;
};

function List({ items, ordered }: { items: Item[]; ordered?: boolean }) {
  const rows = shown(facts, items).map((item, i) => (
    <li key={i}>
      <Inline text={item.text} />
      {item.items ? <List items={item.items} /> : null}
    </li>
  ));
  return ordered ? <ol>{rows}</ol> : <ul>{rows}</ul>;
}

/** One column of text with an optional "On this page" list: on the left on wide screens, under the title on a phone. */
export function DocPage({ title, dek, effective, blocks, toc = false, figures = {} }: Props) {
  const visible = shown(facts, blocks);
  const sections = visible.filter((b) => b.kind === 'h2');
  const questions = visible.filter((b) => b.kind === 'h3');

  return (
    <div className={toc ? 's-page' : 's-page single'}>
      <div className="s-doc-head">
        <h1>{title}</h1>
        {dek ? <p className="s-dek">{dek}</p> : null}
        {effective ? (
          <p className="s-effective">
            <Inline text={effective} />
          </p>
        ) : null}
      </div>
      {toc ? (
        <nav className="s-toc" aria-labelledby="toc-label">
          <p className="s-toc-label" id="toc-label">On this page</p>
          <ol>
            {sections.map((s) => (
              <li key={s.id}>
                <a href={`#${s.id}`}>{s.text}</a>
              </li>
            ))}
          </ol>
        </nav>
      ) : null}
      <div className="s-doc">
        {visible.map((b, i) => {
          switch (b.kind) {
            case 'h2':
              return <h2 key={i} id={b.id}>{b.text}</h2>;
            case 'h3':
              return <h3 key={i} id={b.id}>{b.text}</h3>;
            case 'p':
              return b.panel ? (
                <div key={i} className="s-panel">
                  <p><Inline text={b.text} /></p>
                </div>
              ) : (
                <p key={i}><Inline text={b.text} /></p>
              );
            case 'ul':
              return b.panel ? (
                <div key={i} className="s-panel">
                  <List items={b.items} ordered={b.ordered} />
                </div>
              ) : (
                <List key={i} items={b.items} ordered={b.ordered} />
              );
            case 'questions':
              return (
                <ul key={i} className="qidx">
                  {questions.map((q) => (
                    <li key={q.id}>
                      <a href={`#${q.id}`}>{q.text}</a>
                    </li>
                  ))}
                </ul>
              );
            case 'figure':
              if (figures[b.name]) return <Fragment key={i}>{figures[b.name]}</Fragment>;
              // A picture the owner still has to supply: a box with the slot text.
              return b.text ? (
                <div key={i} className="s-photo">
                  <p><Inline text={b.text} /></p>
                </div>
              ) : null;
          }
        })}
      </div>
    </div>
  );
}
