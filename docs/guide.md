# Prompter guide

Everything past the [README](../README.md): installing on your own iPhone and Apple Watch, using the prompter day to day,
Prompter for Mac, sync, sharing with TestFlight, and fixing common problems.

- [Install it on your iPhone and Apple Watch](#install-it-on-your-iphone-and-apple-watch)
- [Using Prompter](#using-prompter)
- [Prompter for Mac](#prompter-for-mac)
- [Sync with your Mac](#sync-with-your-mac)
- [Sharing with others (TestFlight)](#sharing-with-others-testflight)
- [Troubleshooting](#troubleshooting)

---

## Install it on your iPhone and Apple Watch

This takes about 20 minutes the first time, mostly Xcode downloading and signing things.

**Free or paid Apple ID?**

| | Free Apple ID ("Personal Team") | Paid Apple Developer Program |
|---|---|---|
| Install on your own iPhone and watch | ✅ | ✅ |
| How long the installed app keeps working | **7 days**, then reinstall from Xcode | **1 year** |
| TestFlight (installing on other people's phones) | ❌ | ✅ |

Prompter is coming to the App Store as a free download. Until it is listed, you build and install it yourself from this repo, as described here. The code is free software under the GPL (see [LICENSE](../LICENSE)); the Prompter name and icon are not covered by it.

### 1. Set up the Mac

1. Install **Xcode** from the Mac App Store and open it once.
   - If Xcode shows a "Components" screen offering iOS/watchOS downloads, you can switch them off and continue. Simulators
     aren't needed to install on a real device.
2. Install XcodeGen with [Homebrew](https://brew.sh): `brew install xcodegen`
3. In Xcode: **Settings → Accounts → + → Apple Account**, and sign in with your Apple ID.

### 2. Get the code and set your signing details

```bash
git clone https://github.com/superalex051/prompter.git
cd prompter
cp Config/Local.xcconfig.example Config/Local.xcconfig
open -e Config/Local.xcconfig        # or any text editor
```

Fill in the two values (`Config/Local.xcconfig` is git-ignored, so your details never get committed):

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.yourname
```

- **`DEVELOPMENT_TEAM`** is your 10-character **Team ID**.
  - **Paid account:** it's on developer.apple.com → Account → Membership details.
  - **Free account, or if you can't find it:**
    1. Leave the value empty for now, run `xcodegen generate` and open `Prompter.xcodeproj`.
    2. Select the **Prompter** target → **Signing & Capabilities** → pick your team ("Your Name (Personal Team)" for a free
       Apple ID).
    3. Then go to **Build Settings**, search for "Development Team", and copy the ID into `Local.xcconfig`.
- **`BUNDLE_ID_PREFIX`** has to be unique to you, because bundle IDs are unique across all of Apple. For example
  The committed default is `com.example`, which Apple will not register for a device install, so always set your own. For example
  `com.yourname` gives `com.yourname.prompter` for the phone app and `com.yourname.prompter.watchkitapp` for the watch app.

Then generate the project:

```bash
xcodegen generate
open Prompter.xcodeproj
```

Run `xcodegen generate` again whenever you pull new changes or edit `project.yml` or `Local.xcconfig`. The `.xcodeproj` is
generated and not stored in git.

### 3. Install on your iPhone

1. Plug the iPhone into the Mac with a cable, unlock it, and tap **Trust** when asked.
2. Turn on **Developer Mode** on the iPhone: **Settings → Privacy & Security → Developer Mode**, then restart when asked.
   - The switch only appears after the iPhone has been connected to Xcode once.
3. In Xcode, pick the **Prompter** scheme and your iPhone as the run destination, using the device menu at the top of the
   window. Press **Run** (⌘R).
   - The first build creates your development certificate and registers the phone, which takes a few minutes. If it fails
     with *"Build input file cannot be found: …mobileprovision"*, press Run again. That's a one-time race in Xcode's automatic
     signing.
4. **Free Apple ID only:** iOS blocks the app at first. Go to **Settings → General → VPN & Device Management**, tap your Apple
   ID under Developer App, then tap **Trust**.

### 4. Install on your Apple Watch (optional)

The watch app is built into the iPhone app, but its signing must also include your watch, so Xcode has to see the watch once.

1. Keep the watch paired with the iPhone, **unlocked** and close by, and the iPhone plugged in and unlocked. The Mac, iPhone and
   watch should be on the same Wi-Fi with Bluetooth on.
2. In Xcode, open **Device Hub** (⇧⌘2; older Xcode versions call it "Devices and Simulators"), select your iPhone and wait until
   the watch appears under it. The first connection can take a few minutes.
3. On the watch, turn on **Developer Mode**: **Settings → Privacy & Security → Developer Mode**. It restarts; confirm afterwards.
4. In Xcode, choose the **PrompterWatch** scheme with **your watch** as the destination and press **Run**. This registers the
   watch and installs the app on it.
   - Alternatively, after step 2 run the iPhone app again, then on the iPhone open the **Watch** app → My Watch → **Available
     Apps** → Prompter → **Install**.
5. Recommended: on the watch, set **Settings → General → Return to Clock → Prompter** to a long timeout, so the remote stays
   on screen during a take.

<details>
<summary><b>Command-line install (instead of pressing Run in Xcode)</b></summary>

```bash
# find your devices' identifiers
xcrun devicectl list devices

# iPhone: build signed for the phone, install, launch
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration Debug \
  -destination 'id=<IPHONE-UDID>' -derivedDataPath build/DerivedDataDevice \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <IPHONE-UDID> \
  build/DerivedDataDevice/Build/Products/Debug-iphoneos/Prompter.app
xcrun devicectl device process launch --device <IPHONE-UDID> <your-prefix>.prompter

# Apple Watch: build for the watch (this registers it), then install
xcodebuild -project Prompter.xcodeproj -scheme PrompterWatch -configuration Debug \
  -destination 'id=<WATCH-UDID>' -derivedDataPath build/DerivedDataDevice \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <WATCH-UDID> \
  build/DerivedDataDevice/Build/Products/Debug-watchos/PrompterWatch.app
```
</details>

### Updating later

`git pull`, then `xcodegen generate`, then Run again in Xcode. Your scripts and settings stay on the device.

---

## Using Prompter

### First run
The library starts with a sample script, **"Welcome to Prompter"**, that walks you through the controls. Tap **Prompt** on any
script to open the prompter, then **tap the screen** to start the countdown.

### Setting up a glass rig
1. Put the phone flat, screen up, under the glass, in landscape. Hold it the way it will sit in the cradle when you tap
   **Prompt**: the landscape side is locked from that moment.
2. Mirroring is on by default, so the reflection reads correctly. If the text is upside down in the glass, set
   **Settings → Rotation → 180°**.
3. If the reflection shows a faint double image, make the text bigger and heavier. The defaults are already chosen for this.

### Touch
| Gesture | Does |
|---|---|
| Tap | Start (with the countdown) / pause / resume |
| Drag up or down | Scrub through the script (pauses) |
| Pinch | Text size, live; keeps your place |
| Long-press, or two-finger tap | Settings |
| ✕ (top corner) | Close the prompter. It hides while playing; tap once to show it. |

### Keyboard and clickers
Works with Bluetooth presentation clickers and keyboards.

| Key | Does |
|---|---|
| Space or Return | Start / pause |
| ↓ → Page Down | Forward a line (hold Shift for a paragraph) |
| ↑ ← Page Up | Back a line (hold Shift for a paragraph) |
| + / − | Faster / slower |
| 0 | Back to the top |
| Esc | Close the prompter |

### Apple Watch
Open the prompter on the iPhone first, then open Prompter on the watch.

| Control | Does |
|---|---|
| Big round button | Start / Pause / Resume (shows the countdown digit and the time left) |
| Digital Crown | Speed |
| + / − | Speed in bigger steps |
| ⤒ | Back to the top |
| ↺ | Jump back to the start of the paragraph |

If the iPhone app is in the background or the phone is locked, the watch asks you to open Prompter on your iPhone. A hidden
countdown never starts. The watch can also control Prompter for Mac through the iPhone: see
[Apple Watch as the remote for the Mac](#apple-watch-as-the-remote-for-the-mac).

### Pace modes (Settings → Scrolling)
- **Speed:** 1 to 10. The speed is measured in lines per second, so a bigger font keeps the same pace.
- **Finish in:** pick a duration and the speed adapts so the script ends on time, even after you pause or scrub.
- **Words per minute** (WPM): default 140. The time left assumes this pace.
- **Voice:** follows your voice (see below).

### Script markup
```
Welcome back to the channel.
// Smile here, look at the lens            ← a note: dimmed, small, not read or counted
[pause 2]                                   ← holds the text for 2 seconds (1 to 60), shown as an amber PAUSE line
Today we're looking at…
```
Only whole lines count as markup, so `//` inside a URL or "[pause]" inside a sentence stay ordinary text.

### Markdown formatting
On by default (Settings → Text → Markdown formatting, on the iPhone, on the Mac and in the Presenter view's settings). A script
without Markdown looks exactly the same either way.
```
# Cold open                                 ← a section title: amber, a little larger, not read or counted
Most people **freeze** on camera.           ← bold shows in amber; *italic* in italics; ~~strike~~ struck through and dimmed
- Read from the glass                       ← a bullet (•); "1. " keeps its number; "> " quotes show as plain text
---                                         ← a thin dividing line
See [my site](https://example.com).         ← links show only their text; `code` shows as plain text; \* shows a real *
```
A marker without its partner (`**bold`) shows as typed, so nothing is ever swallowed. `// notes` and `[pause N]` lines win over
Markdown. Word counts and read times count the words the teleprompter shows. Headings, like notes, hold no spoken words: they
scroll past at your pace without slowing it. The Mac editor shows the Markdown as you type (markers dimmed); the iPhone editor
stays plain text.

### Voice-follow
Set **Settings → Scrolling → Voice**. After the countdown the text moves only as you read it: the line you're on comes up to
the reading line, and it waits when you stop talking. Ad-libs don't move it, and skipping ahead catches up after a few words.
Recognition uses Apple's on-device speech model. The first time, iOS may download it, which needs internet once. The
microphone is only on while a voice take is playing. If the microphone isn't allowed, the prompter says so and scrolls at your
WPM pace instead.

### Siri, Shortcuts and the Action button
"Start Prompter", "Pause Prompter" and "Resume Prompter" work with Siri and appear in the Shortcuts app. To use the Action
button, go to **Settings → Action Button → Shortcut → Start Prompter**. They act on the open prompter.

---

## Prompter for Mac

A native Mac app with the same prompter, built for a MacBook with a teleprompter screen (a monitor in a hood, a beam-splitter
glass) connected over HDMI. You write and run everything from the laptop.

- **Library and editor:** the script list on the left (search; title, first line, word count and read time), the editor on the right.
  ⌘N new, ⇧⌘V paste as new script, ⌘O import `.txt`, `.md`, `.rtf` and `.pdf` (or drop files on the window), ⌘D duplicate, Delete to delete
  (⌘Z brings it back), ⌘↩ to prompt.
- **Prompt:** the text goes **full screen on the teleprompter screen**, mirrored by default, with the reading line, the countdown
  and a small status strip. A control view, the Presenter view, fills the laptop's screen.
- **Settings (⌘,):** pace, countdown, text, mirror and rotation, reading line, the sample script and iPhone sync, in tabs. The
  same settings are in the Presenter view's own panel, and changes show on the teleprompter screen at once.

### Run it

You don't need an Apple ID: the Mac app is signed to run locally on this Mac.

```bash
xcodegen generate
open Prompter.xcodeproj          # choose the PrompterMac scheme and press Run (⌘R)
```

Or build it from the command line and open it:

```bash
scripts/build-mac.sh
open build/DerivedData/Build/Products/Debug/Prompter.app
```

`scripts/test-mac.sh` runs the Mac unit tests. A Mac App Store build would need App Sandbox with the network client and server
entitlements, which this build leaves off.

To keep several of your own Macs up to date, `scripts/deploy-mac.sh` builds the latest commit on `main` and installs it in
`/Applications`. `DEPLOY_HOSTS` is required: `DEPLOY_HOSTS="" scripts/deploy-mac.sh` updates this Mac only, and
`DEPLOY_HOSTS="user@host other@host" scripts/deploy-mac.sh` also installs over SSH on those Macs. Read the comment at the top of
the script for the one-time SSH setup. It never replaces a Mac App Store copy or an app with a different bundle ID.

### Set up the teleprompter screen

1. Connect the screen over HDMI (an adapter is fine).
2. In **System Settings → Displays**, make sure the screen is **extended**, not mirrored. If **Mirror Displays** is on, the text
   shows on the laptop as well as on the screen, and Prompter can't tell them apart: turn it off.
3. In Prompter, pick a script and press **Prompt** (⌘↩). The text appears on the external screen and the Presenter view on the
   laptop. If you have more than one extra screen, choose which one in the Presenter view.

Mirror (on by default) flips the text left to right for the glass. If the text is upside down in the glass, set **Settings →
Teleprompter → Rotation** to 180°.

### The Presenter view

- A live **preview** of exactly what the teleprompter screen shows. It reads normally by default; switch on **Show as on the
  teleprompter** to see it mirrored.
- **Time left** in big digits, elapsed time, progress, the state (Ready, Starting 3, Playing, Paused, End) and the time of day.
- Big **Start / Pause**, Back to top, Jump back, a line back or forward, and Speed − / +.
- A **settings panel** (the sliders button) for pace, size, colors, reading line, mirror and rotation, and the countdown.
- The script picker (top left), the teleprompter screen picker with its resolution, **Swap screens** (the Presenter view and the
  prompter trade screens) and **Stop presenting**.
- The **Presenter** menu has Start or Pause, Back to top, Swap screens and Stop presenting (⌘.).
- On a MacBook with a notch, nothing sits under the notch.

### Keys while presenting

| Key | Does |
|---|---|
| Space or Return | Start / pause (the first press starts the countdown) |
| ↑ ← Page Up | Back a line |
| ↓ → Page Down | Forward a line |
| Shift with any of those | A paragraph at a time |
| − / + | Slower / faster |
| 0 | Back to the top |
| Esc | Pause a running take. Press it again to stop presenting. |

### Apple Watch as the remote for the Mac

Your Apple Watch can only talk to its iPhone, so the iPhone passes its commands on to the Mac over the paired, encrypted sync
connection (pair them first, see [Sync with your Mac](#sync-with-your-mac)).
1. On the Mac, present a script (select it and click **Prompt**).
2. On the iPhone, open Prompter and tap **Remote for Mac** (the Apple Watch button at the top of the library, or Settings →
   Sync with Mac → Remote for Mac). Keep it open: it keeps the screen awake so the iPhone stays connected, shows what the Mac is
   doing, and has the same buttons as the watch.
3. Open Prompter on the watch. It says **On <your Mac>** under the title, and every control works as it does for the iPhone:
   Start / Pause / Resume (with the countdown), Back to top, Jump back, Speed + / − and the Digital Crown.

A prompter open on the iPhone always comes first: close it to control the Mac. With the iPhone app in the background the link
drops and the watch says **iPhone app in the background**; bring Prompter back and it reconnects. With nothing presenting, the
watch says **Tap Prompt on your iPhone or Mac**. A command usually reaches the Mac in well under a second; the watch-to-iPhone
hop is the slow part.

### With one screen

With only the laptop screen, the output is a normal window on the left and the Presenter view sits beside it. The Presenter view
says "Only one screen found". Plug in the teleprompter screen and the prompter **moves there by itself**. Unplugging it during a
take pauses the take and says so.

---

## Sync with your Mac
Prompter for Mac and the iPhone app keep the same scripts: write or paste a script on one and it shows up on the other within
about a second, while Prompter is open on both and they are on the same Wi-Fi. Edits and deletions sync too, and an iPhone
that was away catches up when you open Prompter. Update the Mac and iPhone apps together: the sync protocol changed in the
latest version, and an app that is one version behind says so instead of syncing.

**Pair them (once):**
1. On the Mac: Prompter → Settings → **iPhone** → **Pair an iPhone** (or File → Pair an iPhone…). A 12-digit code shows for
   5 minutes. (An iPhone that asks for 6 digits has an older Prompter: update it first.)
2. On the iPhone: Settings (gear) → **Sync with Mac**, tap your Mac and type the code.
3. **Local Network:** both devices ask the first time. On the iPhone, tap **Allow** when it asks to find devices on your local
   network. On the Mac, allow Prompter to find devices on your local network, or turn it on later in **System Settings → Privacy
   & Security → Local Network**.
4. Both show the status: "Synced with …" under the iPhone's Scripts title and at the bottom of the Mac's script list.

**Forget** (on either side) unpairs. If both change the same script while apart, the later change wins.

### If sync doesn't work

| Problem | Fix |
|---|---|
| The iPhone doesn't list your Mac | On the Mac open Prompter → Settings → iPhone and click **Pair an iPhone** (the Mac only shows up while it is pairing or paired). Put both on the same Wi-Fi, and turn Local Network on for Prompter on both. |
| The Mac says "Prompter can't be found on your network" | Local Network is off for Prompter. System Settings → Privacy & Security → Local Network → Prompter (the button in Settings → iPhone opens it). |
| "The code expired" or "Too many wrong codes" | Codes last 5 minutes and allow a few tries. Click **Pair an iPhone** again for a new code. |
| The iPhone says "Your Mac no longer recognizes this iPhone" | The Mac forgot it. Tap **Pair again** in Settings → Sync with Mac and enter a new code from the Mac. |
| "Update Prompter" on either device | The two apps must be updated together. Build and install both from the same version of the code. |
| "Pairing data was reset" | The pairing file was damaged and was set aside. Pair again. |

---

## Sharing with others (TestFlight)

This is for builds you make yourself. Installing on someone else's phone from Xcode needs their device next to your Mac. **TestFlight** is the easy way to share. It
needs a paid developer account.

1. Archive and upload: in Xcode, Product → Archive → Distribute → TestFlight, or run `REHEARSAL=1 TEAM_ID=<your team ID> scripts/archive.sh`
   (`REHEARSAL=1` archives your self-build. Without it the script archives the App Store build, which needs a private
   `Config/Store.xcconfig`.)
2. In App Store Connect, create the app record. The store name has to be unique; the home-screen name stays "Prompter".
3. Add testers:
   - **Internal testers** are members of your developer team. They can install right away.
   - **External testers** (anyone, by email or public link) need a one-time Beta App Review, usually about a day.
4. Testers install the **TestFlight** app and accept the invite. Each build works for **90 days**; upload a new one before then
   (`scripts/bump-build.sh` gives the next build number).

The full step-by-step guide, with first-upload gotchas, is in [`docs/testflight-checklist.md`](testflight-checklist.md).

---

## Troubleshooting

| Problem | Fix |
|---|---|
| *"Build input file cannot be found: …mobileprovision"* on the first device build | Run again. It's a one-time race while Xcode creates the profile. |
| *"No account for team"* / *"Signing requires a development team"* | Sign in under Xcode → Settings → Accounts, check `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`, then `xcodegen generate`. |
| *"The app identifier … cannot be registered"* / bundle ID not available | Pick a different `BUNDLE_ID_PREFIX` in `Config/Local.xcconfig`, then `xcodegen generate`. |
| The app won't open on the iPhone (free Apple ID) | Settings → General → VPN & Device Management → trust your developer certificate. |
| The app stopped opening after a week | A free Apple ID's installs expire after 7 days. Run it from Xcode again. |
| The Developer Mode switch isn't there | Connect the device to Xcode once (Device Hub), then look again. |
| The watch doesn't appear in Xcode | Unlock the watch, keep it near the iPhone, use the same Wi-Fi with Bluetooth on, re-plug the iPhone and reopen Xcode. |
| *"Unable to install"* on the watch | The watch isn't in your signing profile yet: run the **PrompterWatch** scheme on the watch once (step 4). |
| The watch says "Open Prompter on your iPhone" | Open the prompter on the iPhone, with the app in the foreground and the phone unlocked. |
| The text shows on the Mac instead of the teleprompter screen (Mac) | Turn off **Mirror Displays** in System Settings → Displays, and make sure the screen is connected before you press Prompt. |
| The text comes up upside down in the glass | Settings → Rotation → 180°, or tap Prompt while holding the phone the way it sits in the rig. |
| No countdown beeps | The beeps are system sounds, so the silent switch mutes them. |
| Voice mode says it's using your set pace instead | Allow the microphone (Settings → Apps → Prompter), and be online once so the speech model can download. |
