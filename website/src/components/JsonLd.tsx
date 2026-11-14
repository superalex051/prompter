/** One JSON-LD block. The data is built from facts, never from user input. */
export function JsonLd({ data }: { data: object }) {
  // "<" is escaped so no text can close the script tag.
  const json = JSON.stringify(data).replace(/</g, '\\u003c');
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: json }} />;
}
