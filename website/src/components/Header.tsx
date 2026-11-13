import { facts } from '../content/facts.ts';

export function Header() {
  return (
    <header className="sticky top-0 z-10 border-b border-hair bg-paper/80 backdrop-blur">
      <nav aria-label="Main" className="mx-auto flex h-13 max-w-5xl items-center justify-between px-5">
        <a href="/" className="text-[19px] font-bold tracking-tight text-ink no-underline">
          {facts.name}
        </a>
      </nav>
    </header>
  );
}
