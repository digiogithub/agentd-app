# Android Auto

Added on 2026-11-25, version 1.10.0; data-only pushes 1.11.0 (needs the agentd Android data mode). Android only (iOS CarPlay is not done).

## What the driver gets

- **Car screen (templated app, Car App Library 1.7.0, IoT category)**. Field test 2026-11-25 (Pixel 10,
  current Android Auto): a sideloaded app in the messaging category is never listed as a templated
  app; with `<uses name="notification"/>` it only showed as a notification-only message list, without
  it not at all. Hence IoT (listed with "Unknown sources") plus `notification` for the messaging
  notifications. `ConversationItem` belongs to the messaging category, so the car screen uses rows
  (`CONVERSATIONS = false` in `CarScreens.kt`); dictation goes through a notification ("Dictar
  instrucción" posts a `talk/<session key>` notice whose Reply is sent as `reply`). Headers from car
  API 7, title + action strip before (`minCarApiLevel` 1):
  - **Panel**: "Esperan tu decisión" (one conversation per agent with an open `agentd ask` question or a
    terminal menu: the car reads it aloud and offers a dictated reply; "Abrir" opens the agent),
    "Bloqueos" (blocked tasks, a tap opens the agent), "Agentes" (the rest: host, status, progress,
    current task). Header action "Actualizar" reconnects the hosts. Rows are capped by the host's
    list limit (`ConstraintManager`), waiting items first.
  - **Agent**: its conversation (the last agent message plus what it waits on; reply by voice),
    the options of the open question or menu as rows (tap = answer / choose), "Escuchar conclusión"
    (text-to-speech of the agent's last message), "Últimas líneas" (the last 8 lines shown and read),
    the blocked tasks.
- **Voice reply** (conversation reply on the car screen, or the reply of a notification through
  Google Assistant): `CarHub.reply` answers the oldest open question (with the option the words name:
  "dos", "la segunda", "sí", "no", or part of the label; else with the words as said), else picks
  the terminal menu option it names (no match = refused, the options are read back), else sends the
  words to the agent's prompt as an instruction. The outcome is shown and spoken.
- **Notifications**: the car engine posts one MessagingStyle notification per open question / menu
  (channel `agentd_alerts`, tag `q/<host>/<id>` or `m/<session key>/<revision>`) with Reply
  (RemoteInput, `SEMANTIC_ACTION_REPLY`, no UI) and Mark as read: the form Android Auto shows and
  Assistant reads. A reply updates the notification with what was said and the outcome; a closed item
  cancels it.

## How it runs

- `CarEngine.kt`: a headless Flutter engine, Dart entry point `carMain` (`lib/main.dart` ->
  `lib/src/car/car_bridge.dart`). It has its own `AppData` (repositories, SSH / relay connections),
  separate from the app's, so the car works with the phone locked and the app closed. Channel
  `agentd/car` (protocol at the top of `car_bridge.dart`).
- Started by: the car session (`AgentdCarAppService`), a notification reply (`CarReplyReceiver`),
  `MainActivity` when Android Auto connects while the app runs, and an agentd FCM push while the phone
  is in the car (`AgentdPushReceiver`, see below). Stopped when no car session is open, the phone is
  not in the car and nothing used it for 2 minutes; its notifications are cancelled then.
- `lib/src/car/car_hub.dart` (pure Dart, tested): snapshot from `buildPanel` + the live sessions'
  menus, notices, actions. Actions wait up to 20 s for the host's board after a cold start, so a reply
  never takes an open question for a free instruction because the board was still loading.
  View-only relay devices get no notices and cannot act.
- `lib/src/car/car_text.dart`: `matchSpokenOption`, `speakable` (code blocks and tables named, markup
  and links removed, cut at 1200 characters), `conclusionOf`, `lastLinesOf`.

## Pushes

Two delivery modes (agentd `push-fcm_plan.md`, "Android data mode"):

- **Data mode** (agentd with the Android data mode): `AgentdPushRepository.register` registers without
  `mode` first (an older daemon rejects unknown fields); when the answer's `modes` lists `data` and the
  effective `mode` is not `data`, it registers again with `mode: "data"` (Android only; a refusal keeps
  the notification registration). The daemon then sends data-only messages (`title`, `body`, `tag` in
  `data`). `AgentdPushReceiver` draws them as a messaging notification with Reply / Mark as read (tag
  `push/<session key>/<reason>`), so the phone and the car show one notification that Assistant reads
  and answers. A `reason: "resolved"` push cancels it (`resolves` = the earlier reason). While the car
  engine runs it draws instead: its notice cancels the push notifications of that session.
- **Notification mode** (older daemons, or iOS): Android draws the push itself, without a reply
  action, so Android Auto ignores it.

In both modes, while the phone is in the car (`CarConnection` projection or native), an agentd push
(`v = 1`, `host_ref`) starts the car engine, which connects and posts its own notification with the
full question and options. The question text never goes through Google unless the daemon has
`include_preview`.

## Limits

- "Hey Google, send a message to <agent> with agentd" needs App Actions (Play Store) and is not
  supported; dictate from the agent's conversation or a notification reply instead.
- Releases accept only Android Auto hosts of `hosts_allowlist_sample`; debug builds accept any host.
- A sideloaded build needs Android Auto's developer settings > "Unknown sources".
- No automated test of the Kotlin side; check it by hand with the Desktop Head Unit (DHU).

## Manual test (Desktop Head Unit)

1. Android Auto app > Settings > tap "Version" 10 times > menu > Developer settings > Unknown sources on,
   then "Start head unit server".
2. `adb forward tcp:5277 tcp:5277` and run `$ANDROID_HOME/extras/google/auto/desktop-head-unit`
   (SDK Manager: "Android Auto Desktop Head Unit Emulator").
3. Open agentd on the head unit: Panel, an agent, "Escuchar conclusión", "Últimas líneas", a dictated
   reply (DHU: `mic` commands), and an `agentd ask` question on a host to see the notification.
