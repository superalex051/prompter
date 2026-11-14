// The rig guide (/rig). Wording from the approved site mockup, built from the support answers and the
// project notes ("1 to 2 m" and "2 mm acrylic"). No download link and no claim that the files are free.
import type { Facts } from './facts.ts';
import type { Block } from './doc.ts';
import { isListed } from './claims.ts';

export const rigTitle = 'How a glass teleprompter rig works';
export const rigDek =
  "Prompter's defaults are set for one setup: an iPhone lying flat under a sheet of glass in front of the camera.";

// The rig band on the home page and the files part here say the same thing about the files.
export const rigFilesLine = 'Printable files for the rig are coming later.';

export function rigBlocks(): Block[] {
  return [
    { kind: 'h2', id: 'setup', text: 'The setup' },
    {
      kind: 'p',
      text: "Your iPhone lies flat, screen up, in landscape, under a sheet of glass or clear acrylic tilted at 45 degrees. You read the text's reflection in the glass, and the camera films you through the glass.",
    },
    { kind: 'figure', name: 'diagram' },
    { kind: 'figure', name: 'photo', text: '[Owner: a photo of your rig]' },

    { kind: 'h2', id: 'mirrored', text: 'Why the text is mirrored' },
    {
      kind: 'p',
      text: 'A reflection flips text left to right. Prompter mirrors the text first, so the reflection reads the right way round.',
    },
    { kind: 'figure', name: 'mirror-pair' },
    {
      kind: 'p',
      text: 'Hold your iPhone the way it sits in the rig when you tap Prompt, because the landscape side locks at that moment. If the text still shows upside down in the glass, set Settings → Rotation → 180°.',
    },

    { kind: 'h2', id: 'second-line', text: 'The faint second line' },
    {
      kind: 'p',
      text: 'Plain acrylic reflects from both of its faces, so every line shows a faint second copy just below it (about 1.5 mm on our 2 mm acrylic rig).',
    },
    { kind: 'figure', name: 'ghost' },
    {
      kind: 'p',
      text: 'Big, heavy, widely spaced white text on black keeps the words readable through that double image, which is why Prompter starts at 72 pt Heavy with 1.6× line spacing.',
    },

    { kind: 'h2', id: 'first-launch', text: 'Set up on first launch', when: (f: Facts) => f.firstRunQuestion },
    {
      kind: 'p',
      when: (f: Facts) => f.firstRunQuestion,
      text: 'The first time you open Prompter, it asks whether you read through teleprompter glass or straight off the screen. Pick Teleprompter glass and it mirrors the text, keeps it in landscape and starts at 72 pt. You can change it later in Settings.',
    },

    { kind: 'h2', id: 'remote', text: 'Run it from where you stand' },
    {
      kind: 'p',
      text: 'You stand 1 to 2 m in front of the camera, out of reach of the phone. Start, pause and change the speed from Apple Watch, and a countdown gives you time to get in place. Apple Watch works with iPhone, not iPad.',
    },
    { kind: 'p', when: (f: Facts) => isListed(f), text: 'Using Apple Watch as a remote is part of Prompter Pro.' },

    { kind: 'h2', id: 'files', text: 'Files for the rig' },
    { kind: 'p', panel: true, text: rigFilesLine },
  ];
}
