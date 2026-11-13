import type { Metadata } from 'next';
import { DocPage } from '../../components/DocPage';
import { supportBlocks, supportDek, supportTitle } from '../../content/support.ts';

export const metadata: Metadata = {
  title: supportTitle,
  description: 'Contact details, requirements, and answers about mirroring, Apple Watch, the Mac and Voice-follow.',
};

export default function SupportPage() {
  return <DocPage title={supportTitle} dek={supportDek} blocks={supportBlocks()} toc />;
}
