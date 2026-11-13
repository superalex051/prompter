# M9: Apple Watch → iPhone → Mac bridge

Goal: the Apple Watch remote controls Prompter for Mac while it presents on the HDMI teleprompter screen. watchOS can only
talk to its paired iPhone (WatchConnectivity), so the iPhone relays over the paired, encrypted sync connection (M7).

## Protocol
- `PrompterStatus` gains two optional fields (left out of the JSON when nil, so older apps read it as before):
  - `deviceName`: set when the status describes Prompter for Mac (the watch shows "On <Mac name>");
  - `note` (`RemoteNote`): why there is nothing to control, when the iPhone knows more than "no prompter":
    `macConnected` ("Tap Prompt on your iPhone or Mac"), `phoneInBackground` ("iPhone app in the background").
    Unknown notes from a newer app decode as `.unknown`.
- `SyncMessage` gains `remoteSubscribe(Bool)` (iPhone → Mac), `remote(RemoteCommand, id:)` (iPhone → Mac) and
  `presenterStatus(PrompterStatus, replyTo:)` (Mac → iPhone; the id ties an answer to its command, so a push already on its
  way can't pass for the answer). An app that doesn't know them skips the frame (SyncConnection already
  ignores messages it can't decode), so the protocol version stays 1. Only identified, paired sessions may use them.
- Non-finite numbers travel as strings in sync JSON too (as in `RemoteMessageCoder`).

## Mac
- `SyncHost`: per peer `wantsPresenterStatus` + the last status sent. `remote` → `remoteHandler` → reply `presenterStatus`
  at once (always). `publishPresenterStatus(_:)` sends to subscribed peers only when what the watch shows changed
  (`LivePushGate.showsDifferently`, moved to `Shared/`).
- `MacRemoteControl` (PrompterMac/App): applies commands through `PresenterSession` (start/pause/togglePlay/speedStep/
  backToTop/jumpBack; resume = togglePlay from paused; setSpeed persists like speedStep). Not presenting → no-prompter
  status, nothing applied. While presenting it samples every 0.25 s and publishes; on stop it publishes "no prompter".
  The Mac's prompter is on screen whenever it presents (`isOnScreen` nil).

## iPhone
- `SyncClient`: subscribes on connect, keeps `presenterStatus` (nil when disconnected), `sendRemote(_:reply:)` with
  waiters by id and a timeout.
- `PrompterRemoteHub`: watch commands route by `RemoteTarget.choose`: an open iPhone prompter wins (exactly as before);
  else a connected Mac that is presenting (forwarded, reply waits for the Mac's answer, max 1.5 s); else no prompter with a
  note. Relayed statuses are re-stamped with the phone's `SequenceClock`; Mac pushes go to the watch through the same
  `LivePushGate` and application context. `handle(_:)` (intents) stays iPhone-only. The app tells the hub when it goes to
  the background.
- WatchConnectivity reply becomes callback-based so a forwarded command can answer later.
- "Remote for Mac" screen (Settings → Sync with Mac when paired, and a library toolbar button when paired): the Mac's status
  big and simple, transport buttons, "Keep this open; your Apple Watch controls the Mac through this iPhone.", idle timer
  off while open. Debug route `-route macRemote`.

## Watch
- `RemoteDisplayModel.deviceText` ("On Studio Mac") under the title; the new notes' texts. Everything else as is.

## Tests
Message round trips + unknown-type tolerance; status coding with the new fields; display model; routing decisions; hub
forwarding (fake relay); Mac command application through `PresenterSession` / refused when not presenting; push gating;
loopback (real `SyncHost` + `SyncClient` over TLS) of a remote command and a status push.

## E2E
`scripts/watch-mac-e2e.sh`: Mac app (`-demoData -syncPort -syncPairingCode -route prompter -presenterSnapshots … -quitAfter`),
iPhone app on "Prompter Dev iPhone" (`-demoData -syncHost -syncPairingCode -route macRemote`), watch app on "Prompter Dev
Watch" (`-remoteScript …`). Logs from all three, Mac presenter snapshots, watch + iPhone screenshots, latencies.
