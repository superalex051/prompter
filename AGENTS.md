# Prompter: iPhone and Mac teleprompter with an Apple Watch remote

Prompter is a native teleprompter for iPhone (and iPad), with a Mac app and an Apple Watch remote. It was built to replace
subscription teleprompter apps that charge a monthly fee just to mirror text. The app is heading to the App Store as a free
download with a one-time Pro unlock: no subscription, no account, no analytics. The source stays public, and building it
yourself with your own Apple developer account keeps working.

## The rig (why the defaults look the way they do)
- An iPhone lies **flat, screen up, in landscape** in a 3D-printed cradle under a 45 degree sheet of **2 mm clear acrylic**.
  The presenter reads the reflection, so the text must be **mirrored horizontally**. The camera films through the acrylic.
- Plain acrylic reflects off both faces, so every line shows a faint **double image about 1.5 mm below** (ghosting).
  A software pre-compensation experiment did not help on the real glass. Fight ghosting with **big, heavy, widely spaced
  white text on pure black** defaults, not shaders.
- The presenter stands 1 to 2 m away at the camera, so the **Apple Watch is the main remote** and a **countdown** gives time
  to get in position.
- Later: an iPad on a bigger tripod rig, so keep layouts size-adaptive (iPhone and iPad, same app).

## Layout
```
Prompter/            iOS app (SwiftUI)
PrompterWatch/       watchOS app, embedded in the iOS app
PrompterMac/         Prompter for Mac
Shared/ Core/        code shared between targets
PrompterTests/ CoreTests/ PrompterMacTests/   unit tests (Swift Testing)
qa/                  Maestro UI flows (screenshots go to qa/output, git-ignored)
scripts/             build, test, QA, deploy and check scripts
Config/              xcconfig files and entitlements; Local.xcconfig and Store.xcconfig are git-ignored
docs/                spec, research, guide, PROGRESS.md, screenshots
website/             getprompter.app: Next.js + Tailwind. Vercel builds website/ from GitHub.
                     website/ has its own AGENTS.md with the site rules.
.inbox/              private notes and plans, git-ignored, never committed
project.yml          XcodeGen source for Prompter.xcodeproj (the .xcodeproj is git-ignored)
```

## Source of truth
1. `docs/superpowers/specs/2026-10-06-prompter-design.md`: the design spec (features, architecture, milestones, acceptance criteria).
2. `docs/research/2026-10-06-teleprompter-feature-research.md`: what commercial apps do and why each feature is in or out.
3. `docs/PROGRESS.md`: running log of what got built and what needs the owner.

If the spec and this file disagree, this file wins for process, the spec wins for product. One exception until the docs rewrite
(REL-24): the status paragraph above and the launch plan override the spec on distribution, pricing and scope (App Store release,
Pro unlock, Mac app, sync), because the spec still lists those as out of scope.

## Commands
```bash
xcodegen generate                       # regenerate Prompter.xcodeproj after adding or removing files
scripts/build.sh                        # build iOS app (+ embedded watch app) for the simulator, no signing
scripts/test.sh                         # run unit tests on a simulator
scripts/build-mac.sh / scripts/test-mac.sh   # Prompter for Mac (PrompterMac target, ad hoc signed, no Apple ID needed)
scripts/qa.sh [flow...]                 # Maestro UI flows in qa/ on a simulator
scripts/sim-shot.sh <name> [delay] -- <launch args>   # install last build, launch (e.g. -demoData -route editor), screenshot
scripts/sync-e2e.sh                     # Mac app + iPhone simulator sync end to end (loopback, -demoData)
scripts/check-public.sh                 # fail if a tracked file or unpushed commit message holds a private term
scripts/check-selfbuild.sh              # free self-build gate: a clean copy builds with no entitlements, Pro on, no iCloud
CONFIG="Store Debug" scripts/test.sh    # the store code; CONFIG works the same in build.sh, build-mac.sh, test-mac.sh, qa.sh
scripts/build-cloud.sh ios <UDID> | mac # signed Store Debug apps with iCloud (the owner, main checkout only)
xcrun simctl list devices available     # find simulator UDIDs
xcodebuild -downloadPlatform watchOS    # one-time: install the watchOS simulator runtime (large download)
xcrun simctl pair <watchUDID> <phoneUDID>   # pair a watch simulator with an iPhone simulator
```
- **Every heavy command goes through `scripts/heavy.sh`**. Heavy means an Xcode build, a simulator,
  a Maestro run, an e2e script, a website build or a Playwright run. Only one heavy task runs at a time across all agents.
  Run it as `scripts/heavy.sh --task <ID> -- <command>`.
- Build for the simulator with `CODE_SIGNING_ALLOWED=NO` (the scripts already do). Device signing reads the team and bundle ID
  prefix from the git-ignored `Config/Local.xcconfig` (copy `Config/Local.xcconfig.example`).
- To run on a real device: run `xcodegen generate`, open `Prompter.xcodeproj`, choose the device, Run. The watch app installs
  through the iPhone's Watch app, or pick the watch as the destination with the `PrompterWatch` scheme.

### Build configurations
- **Debug and Release are the self-build**: every feature on (Pro included), no App Store purchase, no iCloud, no
  entitlements, so a free Personal Team can sign them. They never read `Config/Store.xcconfig`. Neither does
  `scripts/deploy-mac.sh`, which always builds plain Release.
- **Store Debug and Store Release** also read the git-ignored `Config/Store.xcconfig` (copy `Config/Store.xcconfig.example`):
  the `PROMPTER_STORE` and `PROMPTER_CLOUD` switches, plus the team, prefix and iCloud container for each. Store Debug is the
  dev identity `<prefix>.prompter.dev` on iPhone, iPad and Mac (watch: `.prompter.dev.watchkitapp`), with the dev container.
  Store Release is the shipping app; the Mac shares the iPhone's bundle ID there.
- In Swift, read the switches through `BuildFlags` (`Core/Support/BuildFlags.swift`) and iCloud through
  `CloudConfiguration.current()` (`Core/Cloud/`). Never call CloudKit, the key-value store or StoreKit unless
  `CloudConfiguration` or the store switch says so, and never from a test outside an `SKTestSession` or a fake.
- To test store code in a worktree, copy `Config/Store.xcconfig.example` to `Config/Store.xcconfig`; placeholder values are
  fine. Script builds (`build.sh`, `test.sh`, `build-mac.sh`, `test-mac.sh`, `qa.sh`) are never team-signed, carry no
  entitlements and drop the iCloud container in every configuration, and they stop when a Store configuration has no
  `Config/Store.xcconfig`.
- Mac flavors (`PROMPTER_MAC_FLAVOR`): `selfbuild` (ad hoc, not sandboxed, `<prefix>.prompter.mac`) is the script and Xcode
  default. `MAC_FLAVOR=qa` gives the sandboxed ad hoc `<prefix>.prompter.mac.qa`; keep worktrees on selfbuild until the Mac
  sandbox spike clears qa. `store` (team-signed, sandboxed) comes only from the Store configurations, built by
  `scripts/build-cloud.sh`.
- `scripts/archive.sh` archives Store Release and refuses anything that is not a store build; `REHEARSAL=1` archives plain
  Release, the self-build, for an upload rehearsal or a self-builder's own TestFlight. It is never the store app.
- Mac script builds keep the selfbuild flavor in every configuration, so `CONFIG="Store Debug" scripts/test-mac.sh` runs
  as `<Store Debug prefix>.prompter.mac`. In the main checkout that is the daily self-build's bundle ID, on purpose: under
  tests the Mac app uses throwaway storage. The store flavor (`.prompter.dev`) comes only from `scripts/build-cloud.sh mac`.
  It has no network entitlements until MAC-02b, so Mac sync fails in it.

### Maestro
- Maestro is installed at `~/.maestro/bin/maestro` (Java is present). Use it for simulator end-to-end flows of the iPhone app.
  It is a dev tool, so the "Apple frameworks only" rule (which is about app code) does not apply to it. Don't install anything else.
- Flows live in `qa/*.yaml`, one per screen or journey, each leaving screenshots. Every UI change ships with a pass of the
  flows that cover it, and someone opens the PNGs and looks.
- Flows launch with `-demoData` so they never touch real scripts or settings, and they clean up anything they create.
- Maestro can't drive the watchOS simulator; the watch link is checked with the watch app's `-remoteScript` debug option.

### Simulators
- Use the dedicated simulators, by UDID only: "Prompter Dev iPhone" `55CEE99F-DD81-42F7-8F36-4C1D69146658`,
  "Prompter Dev iPad" `8858715C-7371-4BD5-80BA-C0DA5A0EAB6A` and "Prompter Dev Watch" `D5DB695A-92A2-432F-90B7-781EB888FDAB`.
  Scripts find them by exact name (`scripts/lib.sh`). Never address `booted`, never `simctl shutdown all`,
  shut down only what you booted.
- Other sessions may be using their own simulators at the same time. Don't touch devices you didn't start.
- Never read the simulator pasteboard.

## Rules that apply everywhere
- **SwiftUI**, Swift 6 language mode, **Apple frameworks only** (no SPM or CocoaPods dependencies in the app). iOS 26.0+;
  the watchOS target is set in `project.yml`. The website may use pinned npm packages; run `npm audit` whenever they change.
- UIKit only where SwiftUI can't do it well (a TextKit-backed scrolling text view, key commands, display-link timing).
- Observation (`@Observable`), `@MainActor` view models, value-type models, `Codable` persistence (JSON in Application Support,
  settings in `UserDefaults`). WatchConnectivity delegates are `nonisolated` and hop to the main actor.
- The Xcode project is **generated by XcodeGen** from `project.yml`. Never hand-edit `Prompter.xcodeproj`. Add files under the
  source folders and re-run `xcodegen generate`.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). Put logic (scroll math, script parsing, protocol coding)
  in testable types, not views.
- Targets: `Prompter` (iOS app: `Prompter/`, `Core/`, `Shared/`), `PrompterWatch` (watchOS app embedded in the iOS app: `PrompterWatch/`,
  `Shared/`), `PrompterMac` (`PrompterMac/`, `Core/`, `Shared/`), and the unit test targets (`CoreTests/` runs in both
  `PrompterTests` and `PrompterMacTests`).
- The repo is public. Keep out of tracked files and commit messages: personal names, machine names, team IDs, bundle ID
  prefixes, home paths and the owner's other projects. Run `scripts/check-public.sh` before any push. A dash warning on an unpushed commit message must be fixed before the push.
- Stay inside this folder. No `sudo`. Don't install Homebrew packages (XcodeGen is already installed). No changes to signing, keychains, Apple ID or provisioning unless the owner asks.
- Don't delete or reset git history. Don't add third-party code to the app.
- Pushes, and merges into `main`, need the owner's OK. `launch` is the integration branch: finished work merges there first,
  and `launch` goes into `main` only on the owner's word. Never force-push.
- Don't start dev servers on the owner's ports. Website checks use a static server on 127.0.0.1:4517.
- This Mac is also the owner's workstation and often runs several sessions. Keep at most one or two simulators booted, shut them
  down when done, and don't leave runaway processes (a past job hit 90 GB of RAM; watch memory on anything heavy).
- Unattended sessions: work milestone by milestone from the spec, write the plan into `docs/superpowers/plans/` first, and finish
  with a green build and test run, screenshots in `docs/screenshots/`, a `docs/PROGRESS.md` entry and one commit per milestone
  (small commits inside a milestone are fine). If something is blocked (needs the owner, a device, a password, a GUI dialog),
  log it in PROGRESS.md under "Needs the owner" and move to the next unblocked item. Never wait on input.

## Brand
- Black background, large heavy white type, plain words. UI copy is short and literal: "Start", "Pause", "Back to top".
- No promo words, no em dashes or en dashes in anything a person reads. Use a period, comma, colon or the middle dot.
- Write about the owner as "the owner" or "they" in docs.
- The website's text, images and design are all rights reserved; the code license covers code only.

## Working style
- Plain language, short. Say what a person will see or do differently, not the commit subject.
- Plan before a non-trivial build. Check that a screen really renders before calling it done.
- Verify your own work before you report it: run the tests the task names, and say which steps you could not run.
- Security findings of any severity get fixed right away as their own change.
- Builders commit on their own branch as they go. Never rewrite or force-push a shared branch.

## Compact instructions
When compacting, keep: the current task and branch, files changed and why, the last test or build result, open questions for
the owner, and the rules above (heavy.sh for heavy work, dedicated simulators by UDID, no pushes, no dashes in copy).

## Commit trailers
End every commit message with the attribution lines the session gives you (a `Co-Authored-By:` line and a `Claude-Session:` line).
Commit messages are plain language, with no em dashes or en dashes and no personal or machine names.
