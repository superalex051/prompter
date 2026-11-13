// One place for product facts the site states. scripts/check-app-facts.mjs checks them
// against the app source in this repo. Keep this file free of enums and other non-erasable
// TypeScript so node can import it directly in tests.

// coming-soon: no App Store listing yet. preorder and live: the listing exists (Pro, price, badges).
export type StoreState = 'coming-soon' | 'preorder' | 'live';

export type Feature = { id: string; label: string; file: string; pattern: string };

export type Facts = {
  name: string;
  owner: string;
  year: number;
  domain: string;
  supportEmail: string;
  price: { amount: string; currency: string; symbol: string; pendingStoreKit: boolean };
  // Devices in the App Store listing. mac: Prompter for Mac is in the listing (set at device run 2).
  platforms: { iphone: boolean; ipad: boolean; mac: boolean; watch: boolean };
  storeState: StoreState;
  icloud: boolean;
  pro: boolean;
  // The "teleprompter glass or screen" question on first launch has shipped.
  firstRunQuestion: boolean;
  links: {
    home: string;
    features: string;
    rig: string;
    privacy: string;
    support: string;
    github: string;
    githubIssues: string;
    readmeGettingStarted: string;
  };
  features: Feature[];
};

export const facts: Facts = {
  name: 'Prompter',
  owner: 'Florida Focus Creation LLC',
  year: 2026,
  domain: 'useprompter.app',
  supportEmail: 'support@useprompter.app',
  // Pending StoreKit: the price is a plan, not something the app sells yet. US price.
  price: { amount: '9.99', currency: 'USD', symbol: '$', pendingStoreKit: true },
  platforms: { iphone: true, ipad: true, mac: true, watch: true },
  storeState: 'coming-soon',
  icloud: false,
  pro: false,
  firstRunQuestion: false,
  links: {
    home: '/',
    features: '/#features',
    rig: '/rig/',
    privacy: '/privacy/',
    support: '/support/',
    github: 'https://github.com/superalex051/prompter',
    githubIssues: 'https://github.com/superalex051/prompter/issues',
    readmeGettingStarted: 'https://github.com/superalex051/prompter#getting-started',
  },
  // Each feature names a file in this repo and a pattern (as a source string) that must appear in it.
  features: [
    { id: 'mirror', label: 'Mirrored text for a beam splitter', file: 'Prompter/Features/Prompter/PrompterTextView.swift', pattern: 'mirror' },
    { id: 'mirror-default', label: 'Mirroring is on by default', file: 'Core/Models/PrompterSettings.swift', pattern: 'var mirrorHorizontal: Bool = true' },
    { id: 'text-defaults', label: '72 pt Heavy, 1.6x line spacing, 6% margins', file: 'Core/Models/PrompterSettings.swift', pattern: 'var fontSize: Double = 72[\\s\\S]*var lineSpacing: Double = 1\\.6[\\s\\S]*var sideMargin: Double = 0\\.06' },
    { id: 'pace', label: '140 words per minute by default', file: 'Core/Models/PrompterSettings.swift', pattern: 'var wordsPerMinute: Double = 140' },
    { id: 'speed-modes', label: 'Speed, Finish in and WPM modes', file: 'Prompter/Features/Settings/PrompterSettingsForm.swift', pattern: '"Speed"[\\s\\S]*"Finish in"[\\s\\S]*"WPM"' },
    { id: 'countdown', label: 'Countdown before the script starts', file: 'Prompter/Features/Prompter/CountdownOverlay.swift', pattern: 'countdown' },
    { id: 'voice', label: 'Voice following, on device', file: 'Prompter/Features/Prompter/Voice/LiveSpeechSource.swift', pattern: 'Speech' },
    { id: 'watch', label: 'Apple Watch remote', file: 'PrompterWatch/Features/RemoteView.swift', pattern: 'View' },
    { id: 'siri', label: 'Siri and Shortcuts', file: 'Prompter/Intents/PrompterIntents.swift', pattern: 'Start Prompter' },
    { id: 'mac-presenter', label: 'Presenter window on Mac', file: 'PrompterMac/Features/Prompter/PresenterView.swift', pattern: 'View' },
    { id: 'mac-keys', label: 'Mac key legend', file: 'PrompterMac/Features/Prompter/PresenterView.swift', pattern: '"Space", "Return"\\], "Start or pause"[\\s\\S]*"Back a line"[\\s\\S]*"Forward a line"[\\s\\S]*"Slower, faster"[\\s\\S]*"Back to top"' },
    { id: 'mac-remote', label: 'Remote for Mac on iPhone', file: 'Prompter/Features/Remote/MacRemoteView.swift', pattern: 'View' },
  ],
};

export const copyrightLine = `© ${facts.year} ${facts.owner}`;
