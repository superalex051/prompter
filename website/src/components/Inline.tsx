import { tokenize } from '../content/doc.ts';

/** Renders copy text: links, bare URLs and emails as links, and owner slots as marked spans. */
export function Inline({ text }: { text: string }) {
  return (
    <>
      {tokenize(text).map((t, i) => {
        if (t.type === 'link') return <a key={i} href={t.href}>{t.value}</a>;
        if (t.type === 'slot') return <span key={i} className="slot">{t.value}</span>;
        return t.value;
      })}
    </>
  );
}
