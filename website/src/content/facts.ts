// One place for product facts the site states. scripts/check-app-facts.mjs checks them
// against the app source in this repo. Keep this file free of enums and other non-erasable
// TypeScript so node can import it directly in tests.

export const facts = {
  name: 'Prompter',
  owner: 'Florida Focus Creation LLC',
  year: 2026,
  // Pending StoreKit: the price is a plan, not something the app sells yet.
  price: { amount: '9.99', currency: 'USD', pendingStoreKit: true },
  platforms: ['iPhone', 'iPad', 'Mac', 'Apple Watch'],
  storeState: 'coming-soon',
  icloud: false,
  pro: false,
  links: {
    github: 'https://github.com/superalex051/prompter',
    privacy: '/privacy/',
    support: '/support/',
  },
  // Each feature names a file in this repo and a pattern (as a source string) that must appear in it.
  features: [
    { id: 'mirror', label: 'Mirrored text for a beam splitter', file: 'Prompter/Features/Prompter/PrompterTextView.swift', pattern: 'mirror' },
    { id: 'countdown', label: 'Countdown before the script starts', file: 'Prompter/Features/Prompter/CountdownOverlay.swift', pattern: 'countdown' },
    { id: 'voice', label: 'Voice following, on device', file: 'Prompter/Features/Prompter/Voice/LiveSpeechSource.swift', pattern: 'Speech' },
    { id: 'watch', label: 'Apple Watch remote', file: 'PrompterWatch/Features/RemoteView.swift', pattern: 'View' },
    { id: 'mac-presenter', label: 'Presenter window on Mac', file: 'PrompterMac/Features/Prompter/PresenterView.swift', pattern: 'View' },
    { id: 'mac-remote', label: 'Remote for Mac on iPhone', file: 'Prompter/Features/Remote/MacRemoteView.swift', pattern: 'View' },
  ],
} as const;

export const creditLine =
  'Apple, iPhone, iPad, Mac and Apple Watch are trademarks of Apple Inc.';
export const copyrightLine = `© ${facts.year} ${facts.owner}`;
