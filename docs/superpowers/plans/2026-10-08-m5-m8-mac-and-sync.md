# M5–M8: Prompter for Mac + Mac ⇄ iPhone script sync

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.

**Goal (the owner, 2026-10-07):** a native macOS Prompter.
- **External display:** with a MacBook connected to an external screen over HDMI (the screen sits in a teleprompter hood), the
  prompter text shows full screen on that screen.
- **Controls on the laptop:** everything is controlled from the MacBook itself, from its screen and keyboard.
- **Sync:** the Mac app works hand in hand with the iPhone app. A script pasted or written on the Mac shows up on the iPhone by itself.
- **Quality:** built in Swift like the rest, end to end tested, polished.

**Architecture:**
- **Shared core:** the platform-neutral heart of the iPhone app (models, store, importer, settings, markup, scroll engine, layout,
  attributed-text builder) moves into `Core/`, which compiles into both the iOS and macOS apps.
- **macOS app:** `PrompterMac/` (SwiftUI + AppKit where needed) adds a library and editor, a control window on the laptop and a
  borderless full-screen **output window** on the chosen display. The output window is an AppKit TextKit 2 text view driven by
  `NSView.displayLink`.
- **Sync:** Network.framework on the local network:
  - The Mac advertises a Bonjour service and the iPhone finds it.
  - Pairing uses a 6-digit code once. It derives a pre-shared key for TLS, so only paired devices talk.
  - A small framed JSON protocol exchanges library manifests and scripts, merged last-writer-wins with deletion tombstones.

  No accounts, no iCloud, no servers.

**Spec addendum:** this plan is the spec for the Mac and sync work. Everything else stays as in
`docs/superpowers/specs/2026-10-06-prompter-design.md`.

## Global constraints
- Swift 6 strict concurrency, Apple frameworks only, XcodeGen (`project.yml`; never hand-edit the `.xcodeproj`), Swift Testing.
- macOS deployment target 26.0, iOS 26.0, watchOS 10.0.
- The macOS app is not sandboxed for now; it's a direct developer build. Debug builds of it are signed "to run locally" (ad hoc,
  `CODE_SIGN_IDENTITY = "-"`), so nobody's Apple account is needed to build and run it on this Mac. Note in the README what a Mac App
  Store build would need (sandbox + network entitlements).
- **The iOS app must not regress:** `scripts/build.sh` and `scripts/test.sh` (iOS) stay green after every step.
- **Isolation (another Claude session is doing simulator E2E all night):**
  - Use only this session's dedicated simulators, always by UDID:
    - "Prompter Dev iPhone" `55CEE99F-DD81-42F7-8F36-4C1D69146658` (iOS 27.0);
    - "Prompter Dev Watch" `D5DB695A-92A2-432F-90B7-781EB888FDAB`, paired with it.
  - Tests run with `SIM="Prompter Dev iPhone" scripts/test.sh`.
  - Never `xcrun simctl shutdown all`, never the `booted` alias, never other devices; shut ours down by UDID after use.
  - **Maestro on iOS is allowed** (the owner, 2026-10-08), only through `scripts/qa.sh` with `SIM_UDID=55CEE99F-DD81-42F7-8F36-4C1D69146658`; it waits while any other Maestro run is active, so the two sessions never overlap.
  - Never take full-screen captures: they show the owner's other work. Capture only Prompter windows (`screencapture -l <windowID>`, or the
    app's own debug snapshot) and simulator screenshots.
- **RAM:** at most two agents building at a time. Check `memory_pressure` before heavy work. Don't leave apps, simulators or log streams
  running.
- **Displays:** this Mac has a 3440×1440 main screen and a 2560×1440 second screen; use the second one as the stand-in for the HDMI
  teleprompter screen. Close any output window after a test.
- No pushing to GitHub. Commits on `main` are fine.

---

## M5. Shared core + macOS target skeleton · Opus
- Create `Core/` and move into it (with `git mv`) everything platform-neutral that the Mac needs:
  - `Prompter/Models/*`;
  - `ScriptStore`, `ScriptImporter`, `SettingsStore`, `ProtectedDataWait` (iOS-only parts behind `#if os(iOS)`);
  - `Engine/{ScrollEngine,PrompterLayout,DisplayPositionSmoother}` and the timing helpers;
  - `PrompterKeyAction` (keep the UIKit HID map in the iOS app, and add a macOS key-code map in the Mac app);
  - `PrompterDocument`, the attributed-text builder from `PrompterText` (`PlatformFont`/`PlatformColor` typealiases);
  - the TextKit 2 layout extraction (`NSTextLayoutManager` → `PrompterLayout`), which is cross-platform once it's separated from
    `UITextView`.
- Voice-follow, the watch hub, App Intents and UIKit views stay iOS-only.
- `project.yml`:
  - `Core` is added to the sources of `Prompter` and the new `PrompterMac` target.
  - New `PrompterMac` (macOS application, `$(BUNDLE_ID_PREFIX).prompter.mac`, display name "Prompter", app icon from the same art
    via `scripts/make-icons.swift`, dark appearance).
  - New `PrompterMacTests` (macOS unit tests).
  - A `PrompterMac` scheme; `scripts/build-mac.sh` and `scripts/test-mac.sh`.
- The minimal Mac app launches and shows the library list from a `ScriptStore` in `~/Library/Application Support/Prompter/`
  (`-demoData` uses a temp dir).
- **Done when:** the iOS build and tests are green with no behaviour change, and the Mac build and tests are green.

## M6. The Mac app
**6a. Library + editor + settings · Sonnet**
- `NavigationSplitView`: a sidebar with the scripts (search; title, first line and stats as on iOS) and the editor in the detail
  (title, body, live stats, autosave, the markup tip).
- Toolbar and menu:
  - New (⌘N), Paste as New Script (⌘⇧V, `NSPasteboard`), Import… (⌘O; .txt/.rtf/.pdf, also drag and drop onto the window);
  - Duplicate, Rename, Delete (⌫, with Undo ⌘Z);
  - Prompt (⌘↩).
- A Settings scene (⌘,) with the prompter settings (mode/pace, countdown + beep, text, mirror/flip/rotation, reading line) plus
  Restore sample script and Reset.
- Polished, native-Mac look: dark, SF Symbols, the amber accent, proper empty states.

**6b. Prompter output + control window · Opus**
- **Output window:** borderless, full screen on the chosen `NSScreen`:
  - black background; the cursor is hidden over it;
  - the text is mirrored, flipped or rotated per settings (default mirrored for a glass hood), with the reading line and dimming;
  - the HUD strip (time left, progress, state) and the big countdown, all inside the transformed canvas;
  - an AppKit TextKit 2 view moved by `NSView.displayLink` (ProMotion/120 Hz where available);
  - `ScrollEngine` with the same semantics as iOS.
- **Display choice:**
  - lists screens by name (`NSScreen.localizedName`) and auto-picks the external screen when there is one;
  - remembers the choice;
  - reacts to screens connecting or disconnecting (`didChangeScreenParametersNotification`);
  - with a single screen, offers a window on the same screen.
- **Presenter view on the laptop** (confirmed with the owner, 2026-10-07: like PowerPoint's presenter view):
  - **Layout:** it takes over the laptop screen **full screen** while the prompter is on the output display; Esc leaves presenting.
    On a single-screen Mac, the output is a window and the Presenter view sits beside it.
  - **Live preview** of exactly what the output shows (position, countdown, dimming), rendered **readable**, i.e. unmirrored, by
    default, with a toggle "Show as on the teleprompter" that applies the same mirror, flip and rotation.
  - **Timing:** big time left, elapsed time, a progress bar, the state (Ready, 3-2-1, Playing, Paused, End) and the script title.
  - **Transport:** large Start/Pause, Back to top, Jump back a paragraph, step a line back or forward, Speed − / + with the current
    speed label.
  - **Live settings panel**, changes visible on the output instantly: pace mode and value, text size, mirror, flip, rotation,
    countdown, margins, reading line.
  - **Script switcher**, the output display picker with a swap button, and "Stop presenting".
  - **Polish:** dark, large and glanceable, the amber accent.
- **Keys** (when Prompter is the active app): Space/Return start or pause, ↑/↓ and Page Up/Down a line (⇧ a paragraph), +/− speed,
  0 back to top, Esc stop and close the output.
- Prevent display sleep while prompting (`IOPMAssertionCreateWithName`); countdown beeps with `NSSound`.
- Debug launch options for checks:
  - `-demoData`, `-route prompter` (opens the control window and output);
  - `-outputScreen <index|name>`, `-autoStart`;
  - `-snapshot <dir>` (the app writes PNGs of its own windows) and `-quitAfter <seconds>`.

## M7. Mac ⇄ iPhone sync · Opus
- **Core sync logic** (pure, unit-tested):
  - message types (hello, manifest, scripts, deletions, ack);
  - a merge (last writer wins on `updatedAt`, ties broken by device id; deletion tombstones kept 30 days);
  - pairing code → key derivation; framing.
- **Store additions:** `ScriptStore` gains tombstones, `applyRemote(_:)` (no timestamp bump, no echo back) and a change stream.
- **Transport** (Network.framework):
  - the Mac runs an `NWListener` advertising `_prompter-sync._tcp`, and the iPhone runs an `NWBrowser`;
  - TLS 1.3 with a pre-shared key from the pairing code;
  - reconnect with back-off;
  - the iPhone connects while the app is in the foreground.
  - Model it on Apple's "Building a custom peer-to-peer protocol" sample (NWListener + Bonjour + TLS-PSK from a passcode + a framer).
- **Behaviour:**
  - while both apps are open, a script created, pasted or edited on the Mac appears or updates on the iPhone within about a second,
    and the other way round;
  - when the iPhone app is opened later, it catches up;
  - deletions sync.
- **Pairing UI:**
  - Mac Settings → iPhone shows the pairing code and the paired devices with their status;
  - iPhone Settings → Sync with Mac lists the Macs found, takes the code, and shows status and Forget.
  - A small sync indicator in both libraries.
- **iOS Info.plist:** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_prompter-sync._tcp`). The same on macOS.
  `ITSAppUsesNonExemptEncryption` stays false: TLS through Apple's frameworks is exempt. Update the privacy manifests and the TestFlight
  checklist if anything changes.
- **Debug options for E2E:** `-syncPairingCode 123456` on both pairs automatically, and `-syncDemo` makes the Mac create, edit and
  delete a script on a timer.
- **Optional stretch, if time allows:** the Mac as a remote for the iPhone's open prompter, reusing `RemoteCommand` / `PrompterStatus`.

## M8. E2E, polish, docs
- **Mac:** launch with debug options and check by snapshot that:
  - the library looks right;
  - the output on the second screen is mirrored and full screen, with the countdown and the HUD;
  - the control window updates and keys work. Keys are driven through the app's own debug automation, not GUI scripting.
- **Sync:** the Mac app plus the "Prompter Dev iPhone" simulator, both with `-syncPairingCode`:
  - a script created on the Mac appears in the iPhone app (simulator screenshot plus the iPhone app's `scripts.json` read through
    `xcrun simctl get_app_container`);
  - an edit, then a delete, propagate;
  - a script made on the iPhone (debug option) appears on the Mac.
- An independent review (correctness plus UX), then fixes.
- README: a "Prompter for Mac" section (run it, HDMI setup, controls, sync and pairing). PROGRESS entry. Screenshots in
  `docs/screenshots/m5-m8-*`.
- Commit on `main` (no push).
