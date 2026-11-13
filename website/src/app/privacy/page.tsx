import type { Metadata } from 'next';
import { DocPage } from '../../components/DocPage';
import { privacyBlocks, privacyEffective, privacyTitle } from '../../content/privacy.ts';

export const metadata: Metadata = {
  title: privacyTitle,
  description: 'The Prompter app collects no data. What stays on your device, and what this website and Apple see.',
};

export default function PrivacyPage() {
  return <DocPage title={privacyTitle} effective={privacyEffective} blocks={privacyBlocks()} toc />;
}
