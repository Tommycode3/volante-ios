# volante-ios

Volante is a podcast player and voice-note recorder for cars that have Bluetooth
A2DP/AVRCP but no CarPlay, driven entirely from the three steering-wheel buttons. A
double tap records a note that remembers which episode you were listening to and at
what minute. Built for a 2017 Nissan Micra; iOS 17+, SwiftUI, no third-party
dependencies. The UI, spoken prompts and assistant system prompt are in Italian.

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Volante.xcodeproj
```

Set your development team (or `DEVELOPMENT_TEAM` in `project.yml`), change
`bundleIdPrefix`, and run on an iPhone.

| Button | Action |
|---|---|
| Play / Pause | play / pause |
| Next | +30 s |
| Next, double tap (< 450 ms) | voice note |
| Previous | −15 s |
| Previous, double tap | talk to Claude (switchable to "voice note" in Diagnostics) |
| Any button while recording | stop and save |
| Any button while Claude is speaking | interrupt and reopen the mic |

A rising beep means recording has started and the podcast is paused; a falling beep
means the note is saved. Notes close after 2.5 s of silence. The head unit display
shows the recording state through AVRCP metadata, the only visual feedback available
without CarPlay. All of these values are in `AppSettings.swift`.

Transcription is on-device (`SFSpeechRecognizer` with `requiresOnDeviceRecognition`,
Italian by default) and the audio is kept even if it fails. In the Files app under
*On My iPhone > Volante* you get `note.md`, `note.json` (with episode GUID and
position) and the original audio in `NoteVocali/*.m4a`.

## How it works

Head units send only discrete `nextTrack` / `previousTrack` events, so the double tap
is reconstructed in software. The first press is applied at once as a normal skip of
$\delta$ seconds (+30 / −15), so single presses feel instant. If a second press of the
same button arrives within $w$ (`doubleTapWindow`, 450 ms), it undoes the skip and
starts a note instead. The position at note start is therefore the position before
the gesture, and it is frozen as the anchor

$$
\text{anchor} = (\text{episode GUID},\ p_0), \qquad p_0 = \text{player.currentTime at note start}
$$

stored with the episode's audio URL so it survives the episode leaving the feed.
"Replay from here" seeks to $\max(0,\ p_0 - 30\,\text{s})$. "Quote" cuts the window
$[\max(0, p_0 - 45),\ \min(T, p_0)]$ of the downloaded episode (length $T$) with
`AVAudioFile` and transcribes it on-device in the podcast's language, so the note can
be read next to the words that prompted it.

The audio session is `.playAndRecord` from launch and never changes, with
`allowBluetoothA2DP`, no HFP, and the input pinned to the built-in mic on every route
change. Otherwise opening the mic makes the car renegotiate from A2DP stereo to HFP
mono 8 kHz and the podcast sounds like a phone call. The Diagnostics tab shows the
route and every button event, so you can check in the car whether your head unit keeps
A2DP while recording and sends two distinct events for a double tap.

`Loudness.swift` measures each episode with ITU-R BS.1770 (K-weighting, 400 ms blocks,
absolute gate at −70 LUFS plus the relative gate), sampling up to 20 windows instead
of decoding the whole file, and applies

$$
g = \operatorname{clamp}\left(-14 - L_{\text{int}},\ -12\ \text{dB},\ +15\ \text{dB}\right)
$$

so episodes sit at the level of the system voice prompts. `DrivingContext.swift` reads
CoreMotion at 5 Hz and blocks the assistant from speaking during manoeuvres:

$$
\text{manoeuvre}(t) \iff \lVert \mathbf{a} \rVert > 0.22\,g \;\lor\; \lVert \boldsymbol{\omega} \rVert > 0.30\ \text{rad/s},
\qquad
\text{canInterrupt} \iff t - t_{\text{last manoeuvre}} > 4\ \text{s}
$$

Norms make it independent of how the phone sits in its mount.

## Talking to Claude

Optional. It needs an Anthropic API key, stored in the iOS Keychain. Replies stream
from the Messages API (`claude-haiku-4-5` by default) and are spoken sentence by
sentence, so speech starts before the answer is complete. The assistant knows the
current episode, minute and your recent notes, and has tools for EventKit calendar
and reminders, note search, web search, a spoken contact log, WhatsApp (prepared, one
tap to send), Telegram, Slack, GitHub, Notion, and spoken practice sessions
(`Training.swift`). Each tool is offered only if its token or URL is configured, and
the assistant reads back whatever it created since the driver cannot check a screen.
`manda_al_mac` hands longer tasks to Claude Code on your Mac through the
[bridge](bridge/README.md). Also included: an optional trip log with harsh-braking
detection (`Trips.swift`) and Siri / Shortcuts intents (`Intents.swift`).

## Limitations

- Tested on one car and one iPhone. Head units report buttons differently; the
  double-tap window may need tuning.
- No automated tests.
- Italian-only UI and prompts.
- The bridge is meant for a private network (Tailscale) and has no TLS.

## License

MIT. See [LICENSE](LICENSE).
