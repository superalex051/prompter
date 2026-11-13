# Teleprompter feature research (2026-10-06)

Goal: decide what Prompter must do, using the paid apps the owner was going to use as the benchmark. Prompter is a personal app
for one rig: an iPhone flat under 45° acrylic in front of a Sony a7C, with an Apple Watch as the remote.

## Benchmark: Teleprompter.com (App Store id1420515755)
Rated 4.8 (29K ratings). Free "Starter" tier; useful features are behind **Pro**. The US listing shows weekly $4.99,
monthly $9.99 / $19.99, annual $59.99 / $89.99 (the owner saw ~$30/month in-app). One subscription covers iPhone/iPad/Mac/Watch.

Features it advertises:
- **Scrolling:** "VoiceGlide" voice-activated scrolling (follows your voice, pauses when you pause, resumes where you left off);
  fixed speed, **fixed time**, and **words-per-minute** modes; countdown before scrolling; remaining-time indicator and
  progress bar; pinch to zoom text mid-recording.
- **Display:** horizontal and vertical mirroring for beam-splitter rigs; dyslexia-friendly fonts (OpenDyslexic, Lexend);
  right-to-left languages; large text; dark interface; secondary-display output.
- **Remotes:** another iPhone/iPad/Mac, **Apple Watch**, Bluetooth keyboards, presentation clickers, game controllers,
  MIDI controllers, foot pedals. Works offline.
- **Scripts:** write and edit in-app; import TXT, Word and PDF from cloud services; unlimited scripts; AI rephrasing;
  Siri, Spotlight and lock-screen widgets.
- **Recording and post:** 4K recording with front/rear camera switching, trimming, intros/outros, background replacement and blur,
  clean audio, auto subtitles, live captions, live streaming, DockKit gimbals.
- **Cloud:** sync across devices, web access, team workspaces.

Review themes: praised for reliability, ease of use and support. Complaints are about subscription price and auto-renewing
trials, **scroll-speed precision**, and saving individual takes.

## The rest of the field
- **PromptSmart Pro:** known for **VoiceTrack**, an offline voice-following scroll that pauses when you pause and catches up when you
  resume. Good for long talks where a fixed speed creates pressure.
- **Teleprompter Premium:** the "default" pick. Time-based scrolling that keeps moving if you ad-lib. Remotes: **Apple Watch**,
  Bluetooth, keyboard, MIDI.
- **BIGVU:** an all-in-one recording/captioning suite. Prompting is one part of a video workflow.
- **Free web prompters** (Tella, Sozai, Castos, Jupitrr): mirror mode, speed and size. Sozai does voice-follow in the browser.
  They prove the basics shouldn't cost money.
- Across mirror-mode apps, **horizontal mirroring is the most commonly paywalled feature**. It's the one thing a rig can't work without.

## What matters for the owner's rig
| Need | Why |
|---|---|
| Mirror (H, optional V) | The reflection reverses the image |
| Big, heavy, spaced text on black | Hides the 1.5 mm double image from plain acrylic |
| Countdown with big digits + beeps | Start, then walk to the camera |
| Apple Watch remote **with status** | Start/pause/speed from the camera position, and see time left without looking at the glass |
| Speed you can trust (fine steps, WPM/time modes) | The top complaint about the benchmark app |
| Bluetooth clicker / keyboard | Cheap backup remote. Clickers send arrows, Page Up/Down, Space |
| Screen never sleeps | A long take can't be interrupted by auto-lock |
| Paste + Files import | Scripts are written on the Mac and AirDropped or copied over |

## Feature decision for Prompter
**Milestones 1–3, the overnight MVP (must):**
- **Script library:** create, edit, duplicate and delete. Paste from clipboard. Import `.txt` and `.rtf` from Files.
  Show word count and estimated read time.
- **Prompter display:**
  - Mirror H and flip V, landscape or rotate.
  - Text: size, weight, line spacing, margins, colors (white/black default, plus yellow-on-black).
  - **Reading line** marker, with lines above it dimmed.
  - Mirrored **progress bar + time remaining**.
  - Keep the screen awake.
- **Scroll modes:** fixed speed (fine steps), **finish in a set time**, **words per minute**.
- **Countdown:** Off, 3, 5, 10 or 15 s, big mirrored digits, optional beep, haptic on the watch.
- **Touch:** tap to pause/resume, drag to scrub, pinch to resize, long-press for settings.
- **Hardware keys:** Space or Return to play/pause, arrows or Page Up/Down to step a line or paragraph, +/- for speed.
  Covers Bluetooth clickers and keyboards.
- **Apple Watch app:**
  - Controls: Start (runs the countdown), Pause/Resume, speed via **Digital Crown** and ± buttons, Back to top, Jump back a paragraph.
  - Status: script title, state, time remaining, progress ring.
  - Haptics on the countdown and at the end.

**Milestone 4, stretch (should):**
- **Voice-follow scrolling:** on-device Speech framework; the text follows your words and pauses when you pause.
- **Script markup:** `[pause]` cue lines, and `// notes` shown dimmed and not timed.
- **PDF import** via PDFKit.
- **App Intents:** "Start Prompter" / "Pause Prompter" for Siri, Shortcuts and the Action button.
- iPad layout and external-display output for the phase-2 rig.

**Out (won't, for now):** video recording, subtitles/captions, AI rewriting, background replacement, cloud sync or teams,
live streaming, Mac app, any subscription or account. The a7C records; Prompter only prompts.

## Sources
- Teleprompter.com App Store listing: https://apps.apple.com/us/app/teleprompter-com/id1420515755
- Teleprompter.com feature summary: https://www.teleprompter.com/llms.txt and https://www.teleprompter.com/
- Teleprompter.com vs PromptSmart: https://teleprompter.com/compare/teleprompter-vs-promptsmart
- Best teleprompter apps for iPhone in 2026: https://blitzcutai.com/blog/best-teleprompter-apps-iphone-2026
- BIGVU, best teleprompter apps: https://bigvu.tv/blog/best-teleprompter-apps-481af/
- Free browser prompters with mirror mode: https://www.tella.com/tools/teleprompter, https://sozai.app/tools/teleprompter/
