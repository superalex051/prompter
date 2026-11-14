import type { Metadata } from 'next';
import { facts } from '../content/facts.ts';
import { OG_IMAGE, pageMeta, type PageId } from '../content/seo.ts';

/** Title, description, canonical, Open Graph and Twitter card for one page. */
export function pageMetadata(id: PageId): Metadata {
  const p = pageMeta(facts, id);
  const alt = `${facts.name} showing mirrored script text`;
  return {
    title: { absolute: p.title },
    description: p.description,
    alternates: { canonical: p.path },
    openGraph: {
      type: 'website',
      siteName: facts.name,
      locale: 'en_US',
      title: p.title,
      description: p.description,
      url: p.path,
      images: [{ url: OG_IMAGE.path, width: OG_IMAGE.width, height: OG_IMAGE.height, alt }],
    },
    twitter: {
      card: 'summary_large_image',
      title: p.title,
      description: p.description,
      images: [{ url: OG_IMAGE.path, alt }],
    },
  };
}
