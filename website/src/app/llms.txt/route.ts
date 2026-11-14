import { facts } from '../../content/facts.ts';
import { llmsTxt } from '../../content/seo.ts';

export const dynamic = 'force-static';

export function GET() {
  return new Response(llmsTxt(facts), { headers: { 'content-type': 'text/plain; charset=utf-8' } });
}
