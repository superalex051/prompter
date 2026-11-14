import type { Metadata, Viewport } from 'next';
import './globals.css';
import { Header } from '../components/Header';
import { Footer } from '../components/Footer';
import { facts } from '../content/facts.ts';
import { siteUrl } from '../content/seo.ts';
import { pageMetadata } from '../lib/meta.ts';

// Every page sets its own title, description, canonical and cards through pageMetadata().
// These are the defaults for pages that don't (the 404).
export const metadata: Metadata = {
  ...pageMetadata('home'),
  metadataBase: new URL(siteUrl(facts)),
  alternates: undefined,
};

export const viewport: Viewport = {
  themeColor: '#000000',
  colorScheme: 'dark',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <a className="skip" href="#main">Skip to content</a>
        <Header />
        <main id="main">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
