# Voice mode (hands-free, Bluetooth headphones)

Added on 2026-11-27 for version 1.13.0. Android only. Goal: drive the agents without looking at the
screen: hear what they ask and what they concluded, answer, dictate instructions, launch and stop
agents, all through the headphones with Google's own speech engines.

## How the driver uses it

- Start: the launcher icon **"agentd voz"** (also "Hey Google, abre agentd voz"), or Ajustes > Modo
  voz > Activar. A notification "agentd · modo voz" stays while it runs, with **Hablar** and
  **Salir** (also on the lock screen).
- Headphone button: one press = talk (and cuts what is being read: barge-in); double press (next) =
  the last announcement, else repeat; previous = pending items. Long press opens Gemini (the system
  owns it; it cannot be caught).
- Commands (Spanish, free phrasing): "agentes", "pendientes", "uno" / "agente dos" / a name,
  "conclusión" / "qué ha dicho api", "últimas líneas", "pregunta" / "opciones", "opción dos" / "sí" /
  "responde …", "dicta …", "nuevo agente en <proyecto> [con codex] [de <host>]", "para" (Esc),
  "repite", "ayuda", "salir".
- Every send is echoed and confirmed ("A api: «…». ¿Envío?"): "sí" sends, "no" cancels, "repite"
  dictates again; 10 s of silence cancels. Nothing is ever sent by default. Launching and stopping
  ask "¿Seguro?".
- New questions and menus are announced while idle ("api pregunta. Pulsa para oír."), with the music
  ducked, not stopped.
- It leaves by itself after 20 minutes without use ("Salgo del modo voz"): it keeps the hosts
  connected while on.

## Architecture

- Runs in the headless Flutter engine of Android Auto (`CarEngine`, Dart entry `carMain`): its own
  repositories and connections, so the battery rule that disconnects hosts in the background
  (docs/plan.md, Battery) does not cut it. `CarEngine.hold("voice")` keeps the engine while the
  service runs.
- Dart (`lib/src/voice/`, all decisions, tested): `voice_port.dart` (the `VoicePort` interface),
  `voice_grammar.dart` (pure `parse(alts, ctx)` over every recognizer alternative, `parseConfirm`),
  `voice_controller.dart` (state machine: armed, listening, acting, speaking, follow-up, confirming;
  announcements; idle exit), `voice_bridge.dart` (channel `agentd/voice` to `VoicePort`). It reuses
  `CarHub` (snapshot, `reply`, `conclusion`, `lastLines`, plus `interrupt`, `projects`, `launch`) and
  `car_text.dart` (`speakable`, `matchSpokenOption`, `spokenOptions`, `spokenNumber`).
- Kotlin (`android/.../voice/`, thin): `VoiceService` (foreground service, types
  microphone|mediaPlayback, platform `MediaSession` for the media buttons, notification),
  `VoiceSpeaker` (Google TTS `synthesizeToFile` played by our own `MediaPlayer`, USAGE_MEDIA +
  CONTENT_TYPE_SPEECH, so agentd is the app that last played audio and gets the media buttons),
  `VoiceListener` (Google `SpeechRecognizer`, es-ES, 5 alternatives, timeout), `VoiceAudio` (audio
  focus: ducking for speech, exclusive while listening; Bluetooth SCO / BLE headset mic through
  `setCommunicationDevice` only during a listen), `VoiceEarcons`, `VoiceChannel`, `VoiceActivity`
  (transparent trampoline behind the "agentd voz" launcher alias; asks the permissions).

### Channel `agentd/voice` (headless engine)

Dart -> Android: `say {text, lang?}` (completes when played or stopped), `listen {maxMs, lang?,
headsetMic?}` -> `{alts}` or `{error: no_match|timeout|busy|audio|network|permission|other}`,
`earcon {kind}`, `stopSpeaking`, `exit`, `state {text}`. Android -> Dart: `button {key:
playPause|next|previous}`, `started {source: launcher|app|notification}`, `stopped`, `route {bt}`;
queued until Dart sends `ready` on `agentd/car`.

## Platform limits (Android 16, Pixel)

| Wish | Status |
|---|---|
| Start with the headphone button | No: a microphone foreground service cannot start from the background (Android 12+). Start from the icon, Assistant "abre agentd voz", the app or the notification; once on, the button works locked. |
| Headphone button while on | Yes while agentd was the last app to play audio; after Spotify plays, use Hablar in the notification. |
| "Hey Google, abre agentd voz" | Yes (launcher label), sideloaded. A locked phone may ask to unlock. |
| "Hey Google, dile a api que…" (parameters) | Needs App Actions = Play Console (internal track) and Gemini support is uncertain: not done. |
| TTS through the headphones | Yes (A2DP, ducking). |
| Dictation with the headset mic | SCO / BLE headset through `setCommunicationDevice` while listening (call quality meanwhile); to be confirmed on the Pixel 10. Ajustes switch for the phone mic. |

## Manual test (Pixel 10 + Bluetooth headphones)

1. "agentd voz" icon starts it and asks the permissions; "Hey Google, abre agentd voz"; Ajustes >
   Activar.
2. Button after a spoken text: press = listen, double = repeat; with Spotify playing (ducked) and after
   it resumes; screen locked.
3. Dictation through the headset mic: words captured, first ones not lost; audio back to A2DP quality
   after the listen.
4. Commands: list, pick, conclusion, options, "opción dos" + confirm, dictate + confirm, silence
   cancels, launch + confirm, "para".
5. Announcement of a new `agentd ask` while idle.
6. Hablar / Salir in the lock-screen notification; idle exit; Android Auto still works with voice on
   and after.
7. Errors: mic permission denied, flight mode, silence.
