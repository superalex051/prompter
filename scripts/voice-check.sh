#!/usr/bin/env bash
# Voice-follow check on the Mac: the on-device recogniser voice mode uses on the iPhone (SpeechAnalyzer +
# SpeechTranscriber) also runs on macOS 26+, so this compiles the app's own voice files with a small harness
# (scripts/voice-check/main.swift), streams a spoken read-through of a script into them in real time, and prints where
# the reader is after each recogniser update. The simulator has no working speech recogniser, so this is where the
# recognition half of voice-follow can be checked before a device.
#
#   scripts/voice-check.sh                       # speaks the first paragraphs of the demo script with `say`
#   scripts/voice-check.sh read.m4a script.txt   # your own recording and its script
#
# Output in build/voice-check/: the audio, the script, voice-check.results (the recorded recogniser results, timed, for
# the app's DEBUG -voiceReplay option, see scripts/voice-demo.sh) and the compiled harness.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/voice-check
mkdir -p "$OUT"

if [ $# -ge 2 ]; then
  AUDIO="$1"; SCRIPT="$2"
else
  SCRIPT="$OUT/script.txt"
  AUDIO="$OUT/voice-demo.m4a"
  # The first three paragraphs of DemoData's "Channel intro: rig tour".
  cat > "$SCRIPT" <<'EOF'
Hey, welcome back. Today I'm showing you the setup I use to talk straight down the lens without memorizing a single line.

It's simpler than it looks. My phone lies flat on the desk, screen up, in a little cradle I printed. Above it sits a sheet of clear acrylic at forty-five degrees. The camera films through the acrylic, and I read the reflection.

Because the reflection flips everything, the app mirrors the text, so it reads the right way round on the glass.
EOF
  if [ ! -f "$AUDIO" ]; then
    say -v Samantha -r 150 -f "$SCRIPT" -o "$OUT/voice-demo.aiff"
    afconvert -f m4af -d aac -b 64000 "$OUT/voice-demo.aiff" "$AUDIO"
    rm -f "$OUT/voice-demo.aiff"
  fi
fi

V=Prompter/Features/Prompter/Voice
swiftc -swift-version 6 -parse-as-library -O -o "$OUT/voice-check" \
  scripts/voice-check/main.swift \
  "$V/VoiceText.swift" "$V/VoiceAligner.swift" "$V/SpeechTranscript.swift" "$V/SpeechSource.swift" "$V/SpeechBackends.swift" \
  Core/Text/PrompterDocument.swift Core/Models/ScriptMarkup.swift Core/Models/ReadingStats.swift Shared/LogSubsystem.swift

"$OUT/voice-check" "$AUDIO" "$SCRIPT" "$OUT/voice-check.results"
