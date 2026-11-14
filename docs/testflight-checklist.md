# TestFlight checklist (morning steps)

Goal: get Prompter and its watch app from this repo onto the owner's iPhone and Apple Watch through TestFlight.
Team: your Apple developer Team ID. Bundle IDs: `<prefix>.prompter` (iPhone app) and `<prefix>.prompter.watchkitapp` (watch app),
with the team and prefix set in `Config/Local.xcconfig` (see section 2).

## What is already done in the repo
- Version `1.0.0`, build `1`, set once in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) and read by both apps
  through their Info.plists, so the phone and the watch always match (App Store Connect rejects a mismatch).
- Privacy manifests: `Prompter/PrivacyInfo.xcprivacy` and `PrompterWatch/PrivacyInfo.xcprivacy`. No tracking, no tracking domains, no
  collected data. Declared "required reason" APIs: UserDefaults with reason `CA92.1` (phone, for the saved prompter settings) and
  system boot time with reason `35F9.1` (watch remote, to time Digital Crown turns). Both are copied into the built apps.
- `ITSAppUsesNonExemptEncryption = NO` in both apps, so App Store Connect does not ask the export-compliance question.
  Since M7 the phone app does use encryption: Mac ⇄ iPhone sync runs over TLS (TLS 1.2, ECDHE-PSK with ChaCha20-Poly1305) and
  derives keys with CryptoKit's HKDF. All of it is Apple's own (Network.framework, CryptoKit), with no encryption code of
  ours, which is exempt ("uses only encryption in Apple's operating system"), so `NO` stays right.
- Local network (M7): `NSLocalNetworkUsageDescription` ("Prompter finds your Mac on this network to sync your scripts.") and
  `NSBonjourServices` (`_prompter-sync._tcp`) are in the phone app's Info.plist. iOS asks for Local Network access only when
  you open Settings → Sync with Mac (or once paired); an iPhone that never uses sync never asks. No privacy-manifest change:
  sync uses no required-reason API, and the scripts it sends go only to your own Mac, so the answers stay "Data Not Collected".
- Voice mode's purpose strings, `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`, are in the phone
  app's Info.plist (set in `project.yml`). Recognition runs on the device and no audio or text leaves it, so the privacy
  answers stay "Data Not Collected" and the privacy manifest needed no new entry (voice mode uses no required-reason API;
  checked with the `nm`/`strings` commands below on the Release build).
- App icons: 1024 px, opaque (no alpha), light, dark and tinted for the phone, one for the watch.
- The Release build for a real device compiles without signing, with the watch app embedded under `Prompter.app/Watch/`.
- `scripts/archive.sh`, `scripts/ExportOptions.plist` (template) and `scripts/bump-build.sh`.

## 0. First-upload prerequisites (once, before step 1)
These are the things that most often stop a first archive or upload. Do them first.
1. **Accept pending agreements.** At [developer.apple.com/account](https://developer.apple.com/account) accept any updated Apple
   Developer Program License Agreement (a banner at the top of the page), and in App Store Connect > Business (older: Agreements,
   Tax, and Banking) accept anything marked as pending. An unaccepted agreement makes signing or the upload fail with a message
   about a "required agreement". Only the Account Holder can accept the Program License Agreement.
2. **Register at least one device to the team before archiving with automatic signing.** Automatic signing cannot create profiles
   for a team that has no registered device. Run the app once from Xcode on the iPhone (Run, destination = the iPhone) and Xcode
   registers it. For that run:
   - Turn on **Developer Mode** on the iPhone: Settings > Privacy & Security > Developer Mode, switch it on, let the iPhone restart,
     then confirm "Turn On" after the restart (it only appears once a Mac has tried to install a development build).
   - Unlock the iPhone, plug it in, and tap **Trust** on "Trust This Computer?" (enter the passcode).
3. **Run a Release build on the iPhone once, before uploading.** Product > Scheme > Edit Scheme > Run > Build Configuration =
   **Release**, then Run on the iPhone. Open a script, start the prompter, check the countdown, mirroring and scrolling, and
   check that the watch remote still starts and pauses it. A Release build is optimized differently from Debug, so this catches
   problems an upload would not. Set the configuration back to Debug afterwards (or run `xcodegen generate`, which resets the
   scheme).
4. **If the bundle ID is taken** ("An App ID with Identifier ... is not available", or App Store Connect does not offer it): change
   the one line `BUNDLE_ID_PREFIX: <prefix>` in `project.yml` (this is the bundle ID prefix; the phone ID `<prefix>.prompter`,
   the watch ID `<prefix>.prompter.watchkitapp`, the watch's `WKCompanionAppBundleIdentifier` and the test ID are all built from
   it), run `xcodegen generate`, and use the new IDs in step 3 below. Only the simulator QA tooling (`scripts/qa.sh`, `qa/*.yaml`)
   still says `<prefix>.prompter`; it does not affect TestFlight.
5. **Untick Mac and Vision Pro availability if you do not want them.** An iPhone app is offered to Apple silicon Macs and Apple
   Vision Pro by default. In App Store Connect > the app > Pricing and Availability, find the "Apple Silicon Mac" and "Apple Vision
   Pro" availability options and untick them (the prompter is built for the phone and the watch).

## 1. Check the tools
1. Use `/Applications/Xcode.app` (Xcode 27.0, build 27A266a, iOS 27.0 SDK build 24A430) and confirm in Xcode > About Xcode that it is
   a release and not a beta. This Mac also has `Xcode-27.1.0-Beta.app`. Do not archive with a beta Xcode: App Store Connect rejects
   builds made with one. `xcode-select -p` should print `/Applications/Xcode.app/Contents/Developer`.
2. Xcode > Settings > Accounts: the Apple ID for your developer team is signed in and shows the team.
3. In a terminal, from the repo: `xcodegen generate` (recreates `Prompter.xcodeproj`, which is gitignored).

## 2. Set the team (both targets)
Pick one:
- **In Config/Local.xcconfig (recommended, git-ignored, survives `xcodegen generate`):** `cp Config/Local.xcconfig.example
  Config/Local.xcconfig`, set `DEVELOPMENT_TEAM` (your 10-character Team ID) and `BUNDLE_ID_PREFIX` (e.g. `com.yourname`), then
  run `xcodegen generate`. This sets it for every target, including the watch app.
- **In Xcode:** open `Prompter.xcodeproj`, then for **both** `Prompter` and `PrompterWatch` go to Signing & Capabilities and pick the
  team. Keep "Automatically manage signing" on. Running `xcodegen generate` again wipes this, so set it again afterwards.
- **Using only scripts/archive.sh:** nothing to change. The script passes the team on the command line (step 4, route A).

If this is the first time these bundle IDs are used with the account, run the app once on the iPhone from Xcode (Run, destination =
the iPhone). That makes Xcode register both App IDs and gives App Store Connect something to list in step 3. Alternatively create
them at developer.apple.com > Certificates, Identifiers & Profiles > Identifiers > + > App IDs > App, explicit ID.

## 3. Create the App Store Connect app record
1. appstoreconnect.apple.com > Apps > **+** > New App.
2. Platforms: iOS. Primary language: English (U.S.). Bundle ID: pick `<prefix>.prompter` from the list (it only appears once the
   App ID is registered, see step 2). SKU: anything unique, for example `prompter-ios`.
3. Name: "Prompter" is almost certainly taken, and the name must be unique across the whole App Store. Use something like
   "Prompter for Owner". This only changes what App Store Connect and the TestFlight app show. The icon label on the home screen stays
   "Prompter" (`CFBundleDisplayName`).
4. User access: Full Access is fine for a personal app.
5. No separate record is needed for the watch app: it ships inside the iPhone app's record. Its ID
   `<prefix>.prompter.watchkitapp` is registered by Xcode automatically when automatic signing builds the watch target. After the
   first archive, check that it appears under Identifiers at developer.apple.com. If it does not, add it there as an explicit App ID.
6. App Privacy and the App Store listing (screenshots, description, age rating) are only required to submit to the App Store or to give
   external testers a build. For internal testing only, skip them. If asked for privacy answers anyway: "Data Not Collected".

## 4. Archive and upload
Pick one route.

**Route A: script**
```bash
REHEARSAL=1 TEAM_ID=<your team ID> scripts/archive.sh   # the self-build: every feature on, no purchase, no iCloud
TEAM_ID=<your team ID> scripts/archive.sh               # the store build (Store Release); needs Config/Store.xcconfig
```
It archives the `Prompter` scheme (generic iOS device, watch app embedded), stops if the phone and watch apps in the archive
differ in version or build number, exports `build/export/Prompter.ipa`, and prints the next steps. It refuses to run without `TEAM_ID`. Add `DRY_RUN=1` to
run its checks and print the commands without running them.
Without `REHEARSAL=1` it archives Store Release and refuses anything that is not a store build, so a self-build can't reach the
App Store by mistake. `REHEARSAL=1` archives plain Release, the self-build: use it for an upload rehearsal, or to share your
own build with your testers through your own TestFlight. It is never the store app.
Then upload the `.ipa`: open **Transporter** (Mac App Store), sign in with the Apple ID, drag in `build/export/Prompter.ipa`, click
Deliver.

**Route B: Xcode Organizer**
1. Open `Prompter.xcodeproj`, choose the `Prompter` scheme and the destination **Any iOS Device (arm64)**.
2. Product > Archive. Organizer opens when it finishes.
3. Distribute App > TestFlight & App Store (older Xcodes call it App Store Connect) > Distribute. "TestFlight Internal Only", if
   offered, is also fine for personal use. Keep automatic signing, leave "Upload symbols" on, Upload.

If the upload is bounced, App Store Connect emails the reason and Xcode shows it. See "If the upload bounces" below.

## 5. TestFlight: internal group and install
1. App Store Connect > the app > TestFlight. The build shows "Processing" for roughly 5 to 30 minutes, then an email says it finished.
2. Export compliance: nothing to answer, because `ITSAppUsesNonExemptEncryption` is `NO`. If it asks anyway: "Does your app use
   encryption?" answer **Yes**, then that it qualifies for the exemption for encryption that is only Apple's own (the app uses
   TLS through Network.framework and CryptoKit for Mac sync, and no encryption code of its own). No documents are needed.
   The phone and watch talk through Apple's WatchConnectivity.
3. Internal Testing > **+** > create a group (for example "Me"), turn on automatic distribution of new builds if offered, and add the
   Apple ID. That person must be a user of the team (Users and Access, any role that can see the app). Internal testing needs no Beta
   App Review.
4. Add the build to the group if it was not added automatically.
5. On the iPhone, install the **TestFlight** app from the App Store, sign in with the same Apple ID, open Prompter and tap Install.
6. The watch app: on the iPhone open the **Watch** app > My Watch, scroll to Prompter and tap Install (or it installs by itself if
   "Automatic App Install" is on). The watch needs to be paired and on watchOS 10 or newer.
7. TestFlight builds expire after 90 days. Upload a new build before then.

## 6. Quick check on the real devices
- Open Prompter on the iPhone, open the welcome script, tap Prompt, confirm the countdown, mirrored text and scrolling.
- Open Prompter on the watch while the phone prompter is open: the watch should show the remote with Start and Pause working.
- Voice mode: Settings > Scrolling > Voice asks for the microphone once. The first voice take may need a one-time download
  of Apple's speech model (needs internet once); after that it works offline. See "Needs the owner" in `docs/PROGRESS.md`.
- Put the phone in the cradle and check ghosting, brightness and the watch range from 1 to 2 m.

## 7. Next upload (version and build numbers)
- Same version, new build (the common case): `scripts/bump-build.sh` (prints the new build number and edits `project.yml`), then
  archive and upload again. App Store Connect rejects a build number it has already received for the same version.
- New version (for example 1.1.0): change `MARKETING_VERSION` in `project.yml`. The build number may keep counting up (simplest) or
  restart at 1.
- Both numbers apply to the phone and the watch together. Do not set them anywhere else.

## If the upload bounces
- **Missing API declaration (privacy manifest):** new code uses a required-reason API that the manifests do not list. Check what the
  built binary references, then add the matching category and reason to the right `PrivacyInfo.xcprivacy`:
  ```bash
  APP=build/DerivedDataRelease/Build/Products/Release-iphoneos/Prompter.app   # any built Prompter.app, this one is the unsigned Release build
  nm -u $APP/Prompter | grep -E '_stat$|fstat|lstat|getattrlist|mach_absolute_time|statfs|statvfs'
  strings -a $APP/Prompter | grep -E 'systemUptime|creationDate|modificationDate|NSUserDefaults|volumeAvailableCapacity'
  ```
  Run the same two commands on `$APP/Watch/PrompterWatch.app/PrompterWatch` for the watch app.
  Files and timestamps: `C617.1` (app's own container) or `3B52.1` (user-chosen files). Boot time: `35F9.1`. UserDefaults: `CA92.1`.
- **Missing purpose string:** both voice strings are already in `project.yml`. If App Store Connect still names one, the
  `Prompter.xcodeproj` is stale: run `xcodegen generate` and archive again.
- **Duplicate or lower build number:** run `scripts/bump-build.sh`.
- **Phone and watch versions differ:** they cannot, as both read `project.yml`. If it happens, a hand-edited Info.plist or a stale
  `Prompter.xcodeproj` is the cause: run `xcodegen generate`.
- **Provisioning or "no profiles" errors:** confirm the team is selected for both targets, the Apple ID is signed in under Accounts,
  and run the script or Organizer export with automatic signing (it passes `-allowProvisioningUpdates`).
- **Invalid toolchain or SDK:** the archive was made with a beta Xcode. Use `/Applications/Xcode.app`.
