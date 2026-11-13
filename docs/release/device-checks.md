# Real-device checks

Checks that only real hardware can answer. The simulators cannot judge speech recognition, haptics, Bonjour over a real network, Keychain behaviour on a signed build, or the real delay between an iPhone and an Apple Watch.

The owner runs these in three rounds. Do the rounds in order: round 2 builds on what round 1 proves.

## How to use this list

- Before you start, write down the build number and the date.
- Each check has a setup, numbered steps and the expected result.
- Record the outcome in the table under the check: **Pass**, **Fail** or **Skipped** (with the reason in Notes).
- On a Fail, write what you saw, what you expected, and the state the devices were in (screen locked, wrist down, which network).
- Copy the results into `docs/PROGRESS.md` when the round is done. A Fail becomes an issue before the next round starts.
- A tickable page version of this list is kept privately for use on a phone. This file is the reference.

Round 1 covers the features built so far and the pairing fix. Round 2 covers iCloud, first run and accessibility. Round 3 runs on the build that is going to be submitted: purchases, restore, Apple Watch, the Mac, production iCloud and Siri.

| Round | Build | Date | Devices | Result |
| --- | --- | --- | --- | --- |
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |

## Round 1: today's features and the pairing fix

Needs one iPhone, one Apple Watch paired to it, one Mac, and a Wi-Fi network all three can share. A second iPhone is optional (check 1.4).

### 1.1 Release build installs and launches

**Setup.** Build the Release configuration with a signed team and install it on a real iPhone and its paired Apple Watch.

**Steps**

1. Install the iPhone app. Open it.
2. Open the Watch app on the iPhone and confirm the watch app is installed.
3. Open the watch app once.

**Expected.** Both apps open without a crash or a debug banner. No demo library is shown.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.2 Personal Team install

**Setup.** A free Personal Team Apple ID signed in to Xcode, a phone with Developer Mode on, no paid team involved.

**Steps**

1. Set the team to the Personal Team in a throwaway copy of the signing config.
2. Run on the phone.
3. Open the app and create one script.

**Expected.** The app installs and runs. Note which features need a paid team (Keychain access group, iCloud, App Groups) and say what is missing, not only whether it launched.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.3 Keychain move: first launch after the update

**Setup.** A phone that already has paired devices stored by an older build (keys in sync.json). Keep the Mac running so the pair can be checked.

**Steps**

1. Install the new build over the old one. Do not delete the app.
2. Open Prompter, then Settings, then Sync with Mac.
3. Check the Mac is still listed as paired and Connected.
4. Edit a script on the iPhone and watch it appear on the Mac.

**Expected.** Nobody is unpaired and no code is asked for. The Mac stays Connected and the edit arrives within a second or two.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.4 Keychain move: a backup does not clone the pairing

**Setup.** A second iPhone, and a restore of a backup of the first one onto it. If no second phone is available, mark Skipped. Use a restore to a different device, or an encrypted backup. The key is kept for this device only, so a restore onto the same phone does not exercise the check.

**Steps**

1. Restore the backup onto the second phone.
2. Open Prompter on the second phone.
3. On the Mac, look at the paired list.

**Expected.** The second phone shows as not paired. The Mac does not treat it as the first phone. Pairing it needs a fresh code.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.5 Bonjour pairing over real Wi-Fi with the 12-digit code

**Setup.** iPhone and Mac on the same Wi-Fi network (not a hotspot, and not a guest network that isolates clients). Local Network answered Allow for Prompter on both, or reset it first.

**Steps**

1. On the Mac: Prompter, Settings, iPhone, Pair an iPhone. Note the 12-digit code.
2. On the iPhone: Settings, Sync with Mac. Allow local network access when asked.
3. The Mac appears in the list without typing an address. Tap it.
4. Enter a wrong code first. Then enter the right one and tap Pair.

**Expected.** The Mac is found within about 10 seconds. The wrong code is refused with a plain message and the Mac stays unpaired. The right code pairs, and both sides say Connected.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.6 Pairing with Local Network switched off

**Setup.** As 1.5, but Local Network is off for Prompter on the iPhone.

**Steps**

1. Open Sync with Mac and read the message.
2. Follow its button to Settings and turn Local Network on.
3. Go back to the app.

**Expected.** A clear message says Local Network is off and offers a way to Settings. After turning it on, the Mac appears without restarting the app.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.7 Pairing code expires and closes after wrong guesses

**Setup.** As 1.5. A code lives 5 minutes. Wrong guesses are not slowed: after 5 wrong codes in a row, pairing closes.

**Steps**

1. On the Mac, click Pair an iPhone and note the code. Wait 5 minutes (or cancel and click Pair an iPhone again, to get a different code, and use the earlier one).
2. On the iPhone, enter the old code.
3. On the Mac, click Pair an iPhone for a fresh code. On the iPhone, enter 5 wrong codes in a row.
4. Without clicking anything on the Mac, enter the right code.
5. On the Mac, click Pair an iPhone again and enter the new right code.

**Expected.** The old code is refused, and the Mac says the code expired (or is not showing). After 5 wrong codes pairing closes, and the right code is also refused until a fresh code is shown. The fresh code then pairs.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.8 Voice mode

**Setup.** Phone in the rig, quiet room, microphone and speech recognition allowed, a script of at least 200 words.

**Steps**

1. Settings, Scrolling, Voice. Allow the microphone, and speech recognition if asked.
2. Start the prompter in Voice mode and read the script aloud at a normal pace.
3. Pause for 5 seconds, then continue.
4. Skip a sentence on purpose, then read on.
5. Read one section clearly slower and one clearly faster.

**Expected.** The text follows the voice within about a second, holds still during the pause, resumes with speech, and finds its place after the skipped sentence. Note whether iOS used the older fallback recogniser.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.9 Haptics

**Setup.** iPhone in hand, Apple Watch on the wrist. Note the position of the ring and silent switch.

**Steps**

1. Start a 3 second countdown from the iPhone.
2. Start one from the watch.
3. Let a short script finish.
4. Turn the Digital Crown while scrolling.

**Expected.** A click each countdown second, a tap at go, a success tap at the end, and distinct Crown detents. Countdown beeps are silent when the switch is on silent: that is expected.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.10 Watch command latency

**Setup.** iPhone and watch paired and awake, Prompter open on both. A stopwatch, or the phone camera in slow motion.

**Steps**

1. Press Start on the watch. Note the time until the text moves.
2. Press Pause. Note the time until it stops.
3. Repeat five times each.
4. Repeat with the iPhone screen locked, and with the wrist down.

**Expected.** A typical delay under about 1 second with both awake. Record the worst case and the state it happened in. Report anything over 2 seconds.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.11 Watch remote stays on screen

**Setup.** On the watch, Return to Clock for Prompter set to a long timeout.

**Steps**

1. Open the watch remote and lower the wrist for 30 seconds.
2. Raise the wrist.

**Expected.** The remote is still on screen and still controls the prompter.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.12 Smoothness and gestures

**Setup.** Phone in the cradle, 120 Hz display.

**Steps**

1. Scroll a long script slowly, at medium speed and fast.
2. Pinch to resize the text. Two finger tap for settings.

**Expected.** No visible stutter. Gestures work on the first try.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 1.13 Clicker and Shortcuts

**Setup.** A Bluetooth clicker or keyboard, and the Shortcuts app.

**Steps**

1. Pair the clicker. Press Page Up and Page Down in the prompter.
2. In Shortcuts, find Start, Pause and Resume Prompter and run each.

**Expected.** The clicker steps the script. The three shortcuts run.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

## Round 2: iCloud, first run and accessibility

Needs two devices on one Apple Account, plus a Mac. The iCloud storage quota and purge cases are not exercised on devices; check 2.11 records that.

### 2.1 iCloud scripts on two devices

**Setup.** Two devices on one Apple Account, iCloud Drive on.

**Steps**

1. Create a script on device A.
2. Open device B and wait.
3. Edit it on B, then delete it on A.

**Expected.** The script, the edit and the delete each arrive on the other device within a minute.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.2 iCloud settings follow you

**Setup.** As 2.1.

**Steps**

1. Change reading settings (size, speed) on A.
2. Open B.

**Expected.** Reading settings follow. Settings that belong to one device's screen do not.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.3 iCloud off, on, and account switch

**Setup.** One device.

**Steps**

1. Turn iCloud off for Prompter, then on.
2. Sign out and sign in with a different Apple Account.

**Expected.** Local scripts stay. The app asks what to do about the account switch. Nothing is deleted without a question.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.4 Handoff

**Setup.** iPhone and Mac on one Apple Account, Handoff on.

**Steps**

1. Open a script on the iPhone.
2. Look at the Mac Dock.

**Expected.** The Mac offers to continue the same script.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.5 First run

**Setup.** A fresh install (delete the app first).

**Steps**

1. Open the app for the first time on iPhone, iPad if available, and Mac.

**Expected.** A short, clear first screen. No account, no wall. The script list is reached in two taps.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.6 VoiceOver

**Setup.** VoiceOver on.

**Steps**

1. Walk the script list, the editor, Settings and the prompter controls.

**Expected.** Every control has a spoken name and nothing is read twice. Start and Pause work by double tap.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.7 Discovery card

**Setup.** A phone with a watch, one without, and a Mac.

**Steps**

1. Open the app in each state and read the card.

**Expected.** The card shows the right wording for each state and can be dismissed for good.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.8 Mac first run

**Setup.** A clean macOS user account.

**Steps**

1. Open Prompter for Mac for the first time.

**Expected.** First run explains the basics and Local Network. No crash.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.9 Mac Help menu and About

**Setup.** Prompter for Mac.

**Steps**

1. Open each Help menu item and the About panel.

**Expected.** Every link opens the right page. Version and copyright read correctly.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.10 Drag import on the Mac

**Setup.** A plain text, a Markdown and a Word file.

**Steps**

1. Drag each onto the Mac window and the Dock icon.

**Expected.** Each becomes a script. A file that cannot be read gives a plain message.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 2.11 Named as not exercised

**Setup.** iCloud quota and purge.

**Steps**

1. Record that storage full and purged data were not tested on a device.

**Expected.** Written down as not exercised, with the reason.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

## Round 3: the build to submit

Run on the exact build that goes to review. Needs a sandbox tester account and, for the Mac leg, a separate clean macOS user account so the real library is not moved.

### 3.1 Sandbox purchase

**Setup.** Sandbox tester signed in, the build to submit.

**Steps**

1. Open the Pro screen and buy.
2. Quit and reopen.

**Expected.** The purchase completes, Pro unlocks and stays unlocked.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.2 Restore purchases

**Setup.** A second device or a reinstall, same sandbox account.

**Steps**

1. Tap Restore Purchases.

**Expected.** Pro returns. With nothing to restore, a plain message says so.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.3 Cancelled and failed purchase

**Setup.** Sandbox.

**Steps**

1. Cancel the purchase sheet.
2. Trigger a failed payment.

**Expected.** The app stays usable and says what happened.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.4 The Watch on the final build

**Setup.** Phone and watch with the submission build.

**Steps**

1. Repeat 1.9 and 1.10.
2. Look at what a free user sees on the watch.

**Expected.** Same as round 1. Pro prompts read clearly on the small screen.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.5 Mac universal purchase

**Setup.** A separate, clean macOS user account.

**Steps**

1. Install the Mac build.
2. Check that Pro is unlocked by the iPhone purchase.

**Expected.** Pro carries over. The real library is not moved.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.6 Production iCloud

**Setup.** The submission build, real Apple Account.

**Steps**

1. Repeat 2.1 and 2.2 against the production container.

**Expected.** Same results as round 2.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.7 Siri by voice

**Setup.** Siri on.

**Steps**

1. Say "Start Prompter", then "Pause Prompter".

**Expected.** Siri runs the matching action.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.8 About links

**Setup.** The submission build.

**Steps**

1. Open every link in About and Settings.

**Expected.** Each opens the right page: privacy, support, licence.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |

### 3.9 Personal Team install, final build

**Setup.** A free Apple ID.

**Steps**

1. Install the final build with a Personal Team.

**Expected.** Works as recorded in 1.2 with no new surprise.

| Result | Date | Build | Notes |
| --- | --- | --- | --- |
| Pass / Fail / Skipped | | | |
