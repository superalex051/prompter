// The support page text. Wording comes from the reviewed copy; sources for each claim live with that copy.
// Gates: listed = the App Store listing exists (pre-order or live); mac = Prompter for Mac is in the listing;
// icloud = iCloud sync has shipped.
import type { Facts } from './facts.ts';
import type { Block } from './doc.ts';
import { isListed, priceLabel } from './claims.ts';
import { facts as siteFacts } from './facts.ts';

const listed = (f: Facts) => isListed(f);
const notListed = (f: Facts) => !isListed(f);
const mac = (f: Facts) => f.platforms.mac;
const noMac = (f: Facts) => !f.platforms.mac;
const icloud = (f: Facts) => f.icloud;
const noIcloud = (f: Facts) => !f.icloud;

export const supportTitle = 'Support';
export const supportDek = 'Write to us, or find your answer below.';

export function supportBlocks(f: Facts = siteFacts): Block[] {
  const email = f.supportEmail;
  return [
    { kind: 'h2', id: 'contact', text: 'Contact' },
    {
      kind: 'ul',
      panel: true,
      items: [
        { text: `Email ${email}. We reply within 2 business days.` },
        {
          text: `Found a bug, or want something added? Open an issue on GitHub at ${f.links.githubIssues}. Issues are public, so leave out anything private.`,
        },
        {
          text: "Tell us which device you use, its system version, and your version of Prompter. On iPhone or iPad, the Settings app shows Prompter's version under General → iPhone Storage (or iPad Storage) → Prompter. On a Mac, choose Prompter → About Prompter.",
        },
      ],
    },

    { kind: 'h2', id: 'requirements', text: 'Requirements' },
    {
      kind: 'ul',
      items: [
        { text: 'iPhone or iPad with iOS 26 or iPadOS 26 or later.' },
        { text: 'Apple Watch with watchOS 10 or later, paired with your iPhone. Optional. Apple Watch works with iPhone, not iPad.' },
        { text: 'Mac with macOS 26 or later.', when: mac },
      ],
    },

    { kind: 'h2', id: 'restore', text: 'Restore Prompter Pro', when: listed },
    {
      kind: 'ul',
      ordered: true,
      when: listed,
      items: [
        { text: 'Sign in to the App Store with the Apple Account you bought Pro with.' },
        {
          text: 'Open Prompter on your iPhone or iPad, go to Settings → Prompter Pro and tap Restore Purchases. [Owner: confirm the names and place once the UI-01 mockup and PRO-08 are done]',
        },
        { text: 'On a Mac: [Owner: where Restore Purchases sits in Prompter for Mac, from the UI-01 mockup]', when: mac },
      ],
    },
    { kind: 'p', when: (x) => listed(x) && mac(x), text: 'One purchase covers every iPhone, iPad and Mac signed in to the same Apple Account.' },
    { kind: 'p', when: (x) => listed(x) && noMac(x), text: 'One purchase covers every iPhone and iPad signed in to the same Apple Account.' },
    { kind: 'p', when: listed, text: 'Apple Watch uses the Pro on your iPhone.' },
    { kind: 'p', when: listed, text: 'Family Sharing is off for Pro, so each family member buys it on their own Apple Account.' },

    { kind: 'h2', id: 'refunds', text: 'Refunds', when: listed },
    { kind: 'p', when: listed, text: 'Apple handles refunds. Ask for one at https://reportaproblem.apple.com' },

    { kind: 'h2', id: 'questions', text: 'Questions' },
    { kind: 'questions' },

    { kind: 'h3', id: 'subscription', text: 'Is there a teleprompter app without a subscription?' },
    {
      kind: 'p',
      when: notListed,
      text: 'Prompter has no subscription and won\'t get one. Until it reaches the App Store, you can build it yourself for free from the source code on GitHub (see "[Can I build Prompter myself from GitHub?](#build-from-github)" below).',
    },
    {
      kind: 'p',
      when: listed,
      text: `Prompter has no subscription. It's a free download, and Prompter Pro is one payment of ${priceLabel(f)} that you keep.`,
    },
    { kind: 'p', when: listed, text: 'Mirroring and the Speed, Finish in and WPM (words per minute) modes are free.' },
    {
      kind: 'p',
      when: (x) => listed(x) && mac(x),
      text: 'Pro adds Voice-follow, Apple Watch, Siri and Shortcuts as remotes, presenting from a Mac, and more than 5 scripts.',
    },
    {
      kind: 'p',
      when: (x) => listed(x) && noMac(x),
      text: 'Pro adds Voice-follow, Apple Watch, Siri and Shortcuts as remotes, and more than 5 scripts.',
    },
    { kind: 'p', when: (x) => listed(x) && icloud(x), text: 'iCloud sync is free too.' },

    { kind: 'h3', id: 'mirror', text: 'How do I mirror teleprompter text for a beam-splitter glass?' },
    { kind: 'p', text: 'Prompter mirrors the text left to right by default, so its reflection in the glass reads the right way round.' },
    {
      kind: 'p',
      text: 'If the text shows upside down in the glass, set Settings → Rotation → 180°, or hold the phone the way it sits in the rig when you tap Prompt.',
    },
    { kind: 'p', text: 'You can also flip the text top to bottom and rotate it by 90, 180 or 270 degrees.' },

    { kind: 'h3', id: 'apple-watch-remote', text: 'Can I use Apple Watch as a teleprompter remote?' },
    {
      kind: 'p',
      text: 'Yes: Prompter on Apple Watch starts, pauses and resumes the prompter on your iPhone, and the Digital Crown changes the speed.',
    },
    {
      kind: 'p',
      text: 'It also has plus and minus buttons for bigger speed steps, Back to top, and Jump back to the start of the paragraph. It taps your wrist on every second of the countdown.',
    },
    {
      kind: 'p',
      text: 'Open the prompter on your iPhone first, then open Prompter on Apple Watch. If your iPhone is locked or Prompter is in the background, Apple Watch asks you to open Prompter on your iPhone.',
    },
    { kind: 'p', text: 'Apple Watch works with iPhone, not iPad.' },
    { kind: 'p', when: listed, text: 'Using Apple Watch as a remote is part of Prompter Pro.' },

    { kind: 'h3', id: 'mac-external-display', text: 'Can I run a teleprompter on a Mac with an external display?' },
    {
      kind: 'p',
      text: 'Yes: Prompter for Mac puts the text full screen on the external display and fills your laptop screen with a Presenter view.',
    },
    { kind: 'p', text: 'The Presenter view shows a live preview, the time left, and big Start, Pause and speed controls.' },
    {
      kind: 'p',
      text: "In System Settings → Displays, set the external display to extend, not mirror. With Mirror Displays on, Prompter can't tell the two screens apart.",
    },
    {
      kind: 'p',
      text: 'With only one screen, the prompter opens as a window beside the Presenter view and moves to the external display as soon as you plug it in.',
    },
    {
      kind: 'p',
      text: 'Apple Watch can drive the Mac through your iPhone: pair your iPhone with the Mac, then open Prompter on your iPhone, tap Remote for Mac and leave it open.',
    },
    {
      kind: 'p',
      when: noMac,
      text: "Prompter for Mac isn't on the App Store yet. You can build it yourself from the source code on GitHub, and that build needs no Apple Account.",
    },
    { kind: 'p', when: (x) => mac(x) && listed(x), text: 'Presenting from a Mac is part of Prompter Pro.' },

    { kind: 'h3', id: 'voice-follow-languages', text: 'Which languages does Voice-follow understand?' },
    {
      kind: 'p',
      text: "Voice-follow understands the languages that Apple's on-device speech recognition supports on your iPhone or iPad, and it listens in the language your script is written in.",
    },
    {
      kind: 'p',
      text: "Prompter works out the language from the script's text and picks your region's version where Apple has one, such as British English for a phone set to the UK.",
    },
    {
      kind: 'p',
      text: "If your device can't recognize that language, Prompter says so and scrolls at your words-per-minute pace instead.",
    },
    {
      kind: 'p',
      text: "The first time you use a language, your device may download Apple's speech model for it, which needs an internet connection once. After that, Voice-follow works offline.",
    },
    { kind: 'p', text: "Prompter's own buttons and menus are in English." },
    {
      kind: 'p',
      text: "Voice-follow runs on iPhone and iPad. Prompter for Mac has no Voice mode and doesn't use the microphone.",
    },
    { kind: 'p', when: listed, text: 'Voice-follow is part of Prompter Pro.' },

    { kind: 'h3', id: 'restore-pro', text: 'How do I restore Prompter Pro?', when: listed },
    {
      kind: 'p',
      when: listed,
      text: 'On your iPhone or iPad, open Prompter, go to Settings → Prompter Pro and tap Restore Purchases, signed in with the Apple Account you bought Pro with. [Owner: confirm the names and place once UI-01 and PRO-08 are done]',
    },
    { kind: 'p', when: (x) => listed(x) && mac(x), text: 'One purchase covers every iPhone, iPad and Mac on that Apple Account.' },
    { kind: 'p', when: (x) => listed(x) && noMac(x), text: 'One purchase covers every iPhone and iPad on that Apple Account.' },

    { kind: 'h3', id: 'build-from-github', text: 'Can I build Prompter myself from GitHub?' },
    {
      kind: 'p',
      text: "Yes: Prompter's source code is public on GitHub under the GNU General Public License version 3, and you can build it for free.",
    },
    {
      kind: 'p',
      text: `You need a Mac with Xcode 27 or later and XcodeGen. The steps are in the README at ${f.links.readmeGettingStarted}`,
    },
    {
      kind: 'p',
      text: 'A free Apple Account can install it on your own iPhone, but that install stops opening after 7 days. A paid Apple Developer Program membership makes it last a year.',
    },
    { kind: 'p', text: 'Prompter for Mac builds without any Apple Account.' },
    { kind: 'p', when: listed, text: 'Builds you make yourself have Pro switched on.' },
    {
      kind: 'p',
      when: icloud,
      text: 'Builds you make yourself have iCloud sync switched off. They can still sync scripts between iPhone or iPad and Mac once you pair them by code.',
    },

    { kind: 'h3', id: 'glass-rig', text: 'How does a beam-splitter teleprompter rig work with an iPhone?' },
    {
      kind: 'p',
      text: "Your iPhone lies flat, screen up, in landscape, under a sheet of glass or clear acrylic tilted at 45 degrees. You read the text's reflection in the glass, and the camera films you through the glass.",
    },
    { kind: 'p', text: 'Prompter mirrors the text so the reflection reads the right way round.' },
    {
      kind: 'p',
      text: 'Plain acrylic reflects from both of its faces, so every line shows a faint second copy just below it (about 1.5 mm on our 2 mm acrylic rig).',
    },
    {
      kind: 'p',
      text: 'Big, heavy, widely spaced white text on black keeps the words readable through that double image, which is why Prompter starts at 72 pt Heavy with 1.6× line spacing.',
    },
    {
      kind: 'p',
      text: 'Hold your iPhone the way it sits in the rig when you tap Prompt, because the landscape side locks at that moment.',
    },
    { kind: 'p', text: "We don't offer rig files to download yet. Printable files for the rig are coming later." },

    { kind: 'h3', id: 'who-can-read-my-scripts', text: 'Can anyone else read my scripts?' },
    {
      kind: 'p',
      when: noIcloud,
      text: 'No: there are no Prompter accounts and we run no servers, so your scripts stay on your own devices.',
    },
    {
      kind: 'p',
      when: icloud,
      text: 'No: there are no Prompter accounts and we run no servers, so your scripts stay on your own devices and, if you turn on iCloud sync, in your own iCloud account.',
    },
    {
      kind: 'p',
      when: icloud,
      text: "That iCloud copy sits in your private iCloud database, which only your Apple Account can open. We can't read it.",
    },
    {
      kind: 'p',
      text: `Voice-follow recognizes your speech on the device and records nothing. The [privacy policy](${f.links.privacy}) has the details.`,
    },

    { kind: 'h3', id: 'open-prompter-on-iphone', text: 'Why does Apple Watch say "Open Prompter on your iPhone"?' },
    {
      kind: 'p',
      text: 'Apple Watch controls a prompter that is open and on screen on your iPhone, or a Mac you are presenting from while Remote for Mac is open on your iPhone.',
    },
    {
      kind: 'p',
      text: 'Unlock your iPhone and open Prompter. Then tap Prompt on a script, or tap Remote for Mac to control a Mac. A countdown never starts while the prompter is hidden.',
    },

    { kind: 'h3', id: 'iphone-finds-mac', text: "My iPhone doesn't find my Mac. What do I do?" },
    {
      kind: 'p',
      text: 'On the Mac, open Prompter → Settings → iPhone and click Pair an iPhone: the Mac shows up only while it is pairing or paired.',
    },
    {
      kind: 'p',
      text: 'Put both on the same Wi-Fi, and turn on Local Network for Prompter on both: on iPhone in Settings → Privacy & Security → Local Network, on Mac in System Settings → Privacy & Security → Local Network.',
    },
  ];
}
