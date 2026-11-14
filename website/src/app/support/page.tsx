import type { Metadata } from 'next';
import { DocPage } from '../../components/DocPage';
import { JsonLd } from '../../components/JsonLd';
import { facts } from '../../content/facts.ts';
import { breadcrumbLd, faqLd } from '../../content/seo.ts';
import { pageMetadata } from '../../lib/meta.ts';
import { supportBlocks, supportDek, supportTitle } from '../../content/support.ts';

export const metadata: Metadata = pageMetadata('support');

export default function SupportPage() {
  const blocks = supportBlocks();
  return (
    <>
      <JsonLd data={faqLd(facts, blocks)} />
      <JsonLd data={breadcrumbLd(facts, 'support')} />
      <DocPage title={supportTitle} dek={supportDek} blocks={blocks} toc />
    </>
  );
}
