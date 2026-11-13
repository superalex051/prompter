import type { Metadata } from 'next';
import './globals.css';
import { Header } from '../components/Header';
import { Footer } from '../components/Footer';

export const metadata: Metadata = {
  title: 'Prompter',
  description: 'A teleprompter for iPhone, iPad, Mac and Apple Watch. Coming soon.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="flex min-h-screen flex-col">
        <Header />
        <main className="mx-auto w-full max-w-5xl flex-1 px-5 py-20">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
