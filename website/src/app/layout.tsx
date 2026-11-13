import type { Metadata, Viewport } from 'next';
import './globals.css';
import { Header } from '../components/Header';
import { Footer } from '../components/Footer';
import { facts } from '../content/facts.ts';
import { deviceList, subhead, isListed } from '../content/claims.ts';

export const metadata: Metadata = {
  title: {
    default: `${facts.name}: a teleprompter for ${deviceList(facts)}`,
    template: `%s · ${facts.name}`,
  },
  description: `${subhead(facts)}${isListed(facts) ? '' : ' Coming soon to the App Store.'}`,
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
