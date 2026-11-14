import { facts } from '../../content/facts.ts';
import { sitemapXml } from '../../content/seo.ts';

export const dynamic = 'force-static';

export function GET() {
  return new Response(sitemapXml(facts), { headers: { 'content-type': 'application/xml; charset=utf-8' } });
}
