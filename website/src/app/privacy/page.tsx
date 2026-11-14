import type { Metadata } from 'next';
import { DocPage } from '../../components/DocPage';
import { JsonLd } from '../../components/JsonLd';
import { facts } from '../../content/facts.ts';
import { breadcrumbLd } from '../../content/seo.ts';
import { pageMetadata } from '../../lib/meta.ts';
import { privacyBlocks, privacyEffective, privacyTitle } from '../../content/privacy.ts';

export const metadata: Metadata = pageMetadata('privacy');

export default function PrivacyPage() {
  return (
    <>
      <JsonLd data={breadcrumbLd(facts, 'privacy')} />
      <DocPage title={privacyTitle} effective={privacyEffective} blocks={privacyBlocks()} toc />
    </>
  );
}
