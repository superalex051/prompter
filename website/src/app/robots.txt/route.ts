import { facts } from '../../content/facts.ts';
import { robotsTxt } from '../../content/seo.ts';

export const dynamic = 'force-static';

export function GET() {
  return new Response(robotsTxt(facts), { headers: { 'content-type': 'text/plain; charset=utf-8' } });
}
