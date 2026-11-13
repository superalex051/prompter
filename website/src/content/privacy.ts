// The privacy policy text. Wording comes from the reviewed copy; sources for each claim live with that copy.
// Gates: listed = the App Store listing exists (pre-order or live); icloud = iCloud sync has shipped.
// The Mac parts stay on whatever platforms.mac says: people can build Prompter for Mac from the source today.
import type { Facts } from './facts.ts';
import type { Block } from './doc.ts';
import { isListed } from './claims.ts';
import { facts as siteFacts } from './facts.ts';

const listed = (f: Facts) => isListed(f);
const icloud = (f: Facts) => f.icloud;

export const privacyTitle = 'Privacy Policy';
export const privacyEffective = 'Effective [Owner: effective date]';

export function privacyBlocks(f: Facts = siteFacts): Block[] {
  const email = f.supportEmail;
  return [
    {
      kind: 'p',
      text: `This policy covers the Prompter teleprompter app on every device it runs on, and this website, ${f.domain}. ${f.owner} ("we") publishes both.`,
    },

    { kind: 'h2', id: 'short-version', text: 'The short version' },
    {
      kind: 'ul',
      items: [
        {
          text: 'The Prompter app collects no data. It has no accounts, no ads, no analytics and no tracking, and we run no servers for it.',
        },
        { text: "Your scripts and settings are saved on your own devices. We can't read them." },
        {
          when: icloud,
          text: "If you use iCloud sync, your scripts and reading settings also go to your own iCloud account. We can't read those either.",
        },
        { when: listed, text: 'Prompter\'s privacy label on the App Store says "Data Not Collected".' },
      ],
    },

    { kind: 'h2', id: 'on-your-device', text: 'What stays on your device' },
    {
      kind: 'ul',
      items: [
        { text: "Scripts are saved in a file inside Prompter's own storage on each device." },
        { text: "Settings such as speed, text size and mirroring are saved in Prompter's own preferences." },
        {
          text: 'If you back up your iPhone or iPad to iCloud or to a computer, your scripts and settings are part of that backup, like the data of your other apps.',
        },
        {
          text: 'Deleting Prompter from an iPhone or iPad deletes its scripts and settings there. On a Mac, they stay in your Library folder until you delete them.',
        },
      ],
    },

    { kind: 'h2', id: 'icloud-sync', text: 'iCloud sync', when: icloud },
    {
      kind: 'ul',
      when: icloud,
      items: [
        {
          text: 'If you use iCloud sync, Prompter keeps your scripts in your private iCloud database and your reading settings (pace, countdown, colors, text weight, spacing, dimming and Markdown) in iCloud key-value storage. Both belong to your Apple Account.',
        },
        { text: "Apple stores this data. We can't read it and we keep no copy." },
        {
          text: "Your screen setup (mirroring, rotation, text size, margins and the reading line) stays on each device and doesn't sync.",
        },
        {
          text: "When you delete a script, iCloud keeps a small marker with the script's ID and the time you deleted it, so another device can't bring it back. The marker holds none of your text. These markers stay for as long as Prompter's data in your iCloud does.",
        },
        {
          text: 'To delete everything Prompter keeps in iCloud, open Settings on your iPhone, tap your name, then iCloud, then [Owner: confirm the exact menu names on the shipping system], pick Prompter and delete its data.',
        },
        { text: "Apple's Privacy Policy covers how Apple runs iCloud: https://www.apple.com/legal/privacy/" },
      ],
    },

    { kind: 'h2', id: 'voice-follow', text: 'Voice-follow and the microphone' },
    {
      kind: 'ul',
      items: [
        { text: 'Voice-follow is a reading mode on iPhone and iPad that moves the text as you read aloud.' },
        { text: 'Prompter asks for the microphone only when you use Voice-follow, never when the app opens.' },
        { text: 'The microphone is on only while a Voice-follow take is playing.' },
        {
          text: "Apple's speech recognition turns your speech into words on the device. The audio is never recorded or saved, and neither the audio nor the words leave the device.",
        },
        { text: 'Prompter uses the words only to find your place in the script, and forgets them when the take stops.' },
        {
          text: "The first time you use Voice-follow in a language, your iPhone or iPad may download Apple's speech model for it. The download comes from Apple and carries none of your audio or script text.",
        },
        {
          text: 'The permission prompts say:',
          items: [
            {
              text: 'Microphone: "Prompter listens to your voice so the script follows you as you speak. Audio stays on this device."',
            },
            {
              text: 'Speech Recognition: "Speech is recognized on this device to keep the script in step with you." You see this one only when Prompter has to use Apple\'s older speech recognizer, for example on older hardware, for some languages, or when the newer speech model can\'t download. [Owner: at REL-22, look at this prompt on a device. If the system adds Apple\'s sentence about sending speech data to Apple, put this here: "That prompt also shows Apple\'s standard wording about sending speech to Apple. Prompter turns on on-device-only recognition, so your speech is not sent." If it doesn\'t, delete this slot.]',
            },
          ],
        },
        {
          text: 'If you say no, Voice-follow scrolls at your words-per-minute pace instead. You can change your answer later in the Settings app.',
        },
        { text: "Prompter for Mac doesn't use the microphone." },
      ],
    },

    { kind: 'h2', id: 'local-network', text: 'Local network: pairing a Mac' },
    {
      kind: 'ul',
      items: [
        {
          text: "Prompter on your iPhone or iPad and Prompter for Mac can sync scripts directly with each other, over your Wi-Fi or over Apple's peer-to-peer Wi-Fi when the two are close. No server sits in between.",
        },
        {
          text: 'For that, both apps ask for Local Network access. The prompts say:',
          items: [
            { text: 'On iPhone and iPad: "Prompter finds your Mac on this network to sync your scripts."' },
            { text: 'On Mac: "Prompter finds your iPhone on this network to sync your scripts."' },
          ],
        },
        {
          text: 'You pair them once with a 12-digit code that the Mac shows for 5 minutes. The code itself never crosses the network.',
        },
        {
          text: 'Every sync connection is encrypted with TLS, using a key made at pairing that Prompter never sends to anyone else.',
        },
        {
          text: 'On iPhone and iPad the key is kept in the Keychain, on that device only. The Keychain can keep it after you delete Prompter, so choose Forget first if you want it gone.',
        },
        {
          text: "If you built Prompter for Mac yourself, it keeps the key in its pairing file, which only your user account can read. Your Mac's backups include that file.",
        },
        {
          text: 'A Mac that is paired, or showing a code, announces a Prompter service so your iPhone or iPad can find it. Devices on the same network, and Apple devices close by, can see the service and a random ID that stays the same, so a device nearby could recognize the same Mac later. The Mac adds its name only while a pairing code is on screen.',
        },
        { text: 'The Mac syncs only with devices paired with it.' },
        { text: 'To stop syncing, choose Forget on either device.' },
      ],
    },

    { kind: 'h2', id: 'apple-watch', text: 'Apple Watch' },
    {
      kind: 'ul',
      items: [
        {
          text: "Prompter on Apple Watch talks to your iPhone through Apple's built-in connection between Apple Watch and iPhone. That link doesn't need Local Network access and doesn't go through the Mac sync connection.",
        },
        {
          text: "Your iPhone sends Apple Watch the script's title, whether it is playing, how far along it is, the time left and the speed, plus the Mac's name when Apple Watch is controlling a Mac. It never sends the script's text.",
        },
        { text: 'Apple Watch sends back only commands such as start, pause and speed changes.' },
        {
          text: 'When Apple Watch controls a Mac, your iPhone passes those commands to the Mac over the paired, encrypted connection.',
        },
      ],
    },

    { kind: 'h2', id: 'siri-and-shortcuts', text: 'Siri and Shortcuts' },
    {
      kind: 'ul',
      items: [
        {
          text: '"Start Prompter", "Pause Prompter" and "Resume Prompter" work with Siri and Shortcuts. Apple handles your voice request, and Prompter receives only the command.',
        },
      ],
    },

    { kind: 'h2', id: 'purchases', text: 'Purchases', when: listed },
    {
      kind: 'ul',
      when: listed,
      items: [
        {
          text: 'Apple handles every purchase of Prompter Pro through the App Store. We never see your name, Apple Account, card or address.',
        },
        { text: 'To check whether you own Pro, Prompter asks the App Store on your device.' },
        {
          text: "Apple sends us sales totals, such as how many copies sold in each country. Those reports don't say who bought.",
        },
        {
          text: 'Apple also gives us App Store Connect statistics, such as product page views and downloads. For people who chose to share analytics with app developers, it adds sessions and crashes. All of these are totals that don\'t identify anyone.',
        },
      ],
    },

    { kind: 'h2', id: 'crash-reports', text: 'Crash reports from Apple' },
    {
      kind: 'ul',
      items: [
        {
          text: "If you turned on Share With App Developers (on iPhone: Settings → Privacy & Security → Analytics & Improvements), Apple may share crash data and usage statistics about Prompter with us. Apple shares them only in a form that doesn't identify you. Turn that setting off to stop it.",
        },
      ],
    },

    { kind: 'h2', id: 'this-website', text: 'This website' },
    {
      kind: 'ul',
      items: [
        { text: `${f.domain} sets no cookies and runs no analytics, ads or tracking scripts.` },
        {
          when: listed,
          text: "App Store links on this site carry a campaign tag naming the page, so App Store Connect can tell us how many downloads came from each page. Apple reports these as totals and doesn't tell us who you are.",
        },
        {
          text: "Our web host, Vercel, receives the usual details of each visit, such as your IP address, your browser and the page you asked for, so it can deliver the page. It may keep them in short-lived logs [Owner: confirm the log retention for this project]. We don't use them to identify anyone.",
        },
        {
          text: 'If you email us, we get your email address and what you write. We use them only to answer you, and we delete them [Owner: how long you keep support emails].',
        },
        {
          text: 'Email to that address passes through [Owner: forwarding service] to [Owner: mailbox provider], and their privacy policies apply.',
        },
        { text: "GitHub Issues are public and run by GitHub. GitHub's privacy statement applies there." },
      ],
    },

    { kind: 'h2', id: 'children', text: 'Children' },
    { kind: 'p', text: 'The Prompter app collects no data from anyone, children included.' },

    { kind: 'h2', id: 'your-rights', text: 'Your choices and rights' },
    {
      kind: 'p',
      text: `The app sends us nothing. The only information about Prompter that reaches us from Apple is statistics that don't identify you, so we have nothing about you to show, export or delete. To have a support email deleted, write to us at ${email}.`,
    },

    { kind: 'h2', id: 'changes', text: 'Changes to this policy' },
    {
      kind: 'p',
      text: "If this policy changes, we'll post the new version on this page and change the date at the top. Earlier versions stay in the website's public history on GitHub.",
    },

    { kind: 'h2', id: 'contact', text: 'Contact' },
    // The reviewed copy has a mailing-address slot here. The company's address never goes in this public repo,
    // so that line is left out.
    { kind: 'p', text: f.owner },
    { kind: 'p', text: email },
  ];
}
