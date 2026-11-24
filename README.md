# agentd-app

Mobile client (Android and iOS) for coding agents over SSH: a work dashboard and one inbox of
agent sessions across hosts (agentd, zellij, tmux, plain SSH shells), chat view, terminal,
approvals, the agentd mailbox and host provisioning. The desktop client is a separate native app; this project has no
desktop targets.

Two transports:

- **SSH** (everything): the app generates an ed25519 key on the device (secure storage), trusts
  host keys on first use and talks to the agentd daemon through its unix socket over SSH.
- **agentd-relay** (agentd sessions only, no SSH, no open port on the host): the host's daemon and
  the phone both dial out to a self-hosted `agentd-relay`; the tunnel is end-to-end encrypted
  (Noise) and the relay only forwards bytes. See "Relay hosts" below.

Plan and architecture: `docs/plan.md`.

## Development

```sh
export PATH=/apps/flutter/bin:$PATH
flutter analyze
flutter test
flutter run                                    # real repositories
flutter run --dart-define=AGENTD_APP_FAKE=true # in-memory sample data (demos, screenshots)
flutter build apk --debug
```

Tests never run real agent CLIs or installers; the data layer is tested against a fake daemon
and fake remote shells.

## One prompt to several agents

In the Agentes tab, the checklist button of the header (**Seleccionar varios**) turns the list
into checkboxes: a tap picks a session instead of opening it. Quick picks under the filters
select every session shown (**Mostrados**, the filter and the search apply), every session of
one host (when more than one host has sessions that can be picked) or none. The bar at the
bottom sends the text as a prompt to each picked agent at once.

- Only agentd sessions that are running can be picked, on hosts where this device may operate.
  zellij, tmux and terminal-only rows, finished or starting sessions and view-only relay hosts
  are listed but disabled, with the reason.
- An agent that is working gets the prompt anyway (as in the chat); the others get it normally.
- Agents that took the prompt are unselected and counted in the confirmation. Agents that
  refused it stay selected, named with the cause, so you can retry. When all took it, the draft
  is cleared and the selection mode ends. Leaving the mode clears the selection.

## Chat: select, copy, tool calls and code

- Long-press any text of the chat (your prompts, the agent's answer, the output of a tool, code)
  to select it; drag the handles to extend the selection over several paragraphs or entries, then
  **Copy**. **Select all** takes the whole chat that is loaded. The composer takes a paste as any
  text field.
- A tool call of the agent is one card: its name, then, expanded, the whole call (also when the
  command spans several lines) and its output. Calls still being written and MCP calls are cards
  too; none of it shows as prose.
- Code in the agent's answer is a block in a monospace font, as written (no markup), that scrolls
  sideways and has a copy button. This needs agentd 0.8.2 or later on the host; older daemons
  show code as plain text.

## Panel (work dashboard)

The first tab. It shows, across every connected host whose agentd has the
work dashboard (op `board`, agentd 0.8.0 or later):

- **Te esperan**: what needs you. Questions agents asked with `agentd ask` (mailbox messages of
  kind `question`), menus on an agent's terminal (permissions, questions, plans) and tasks an
  agent marked as blocked. The first two are shown; the rest open with "N más".
- **Agentes**: one card per agentd session with the progress of its plan (`done / total`,
  cancelled tasks do not count) and the task in progress. Agents that reported no tasks show
  their status and last line.
- Counters (te esperan, tasks in progress, tasks pending) and a host filter.

Answering without opening the session:

- A question opens a sheet. Tapping one of its options answers it through the mailbox. Your own
  text goes where you choose: **Buzón** replies to the question (the agent gets the reply when
  it is free); **Prompt** types the text in the agent's terminal now, even while it works, and
  then records it as a quiet reply (`reply` with `notify: false`), so the question closes
  without the text being typed twice.
- A permission menu has **Sí** / **No**; other menus list their options in a sheet. Both use
  `act choose` with the menu's revision and epoch, so a screen that changed is refused.
- A card opens the agent's task view: tasks grouped as en curso / bloqueadas / pendientes /
  hechas / canceladas, its open questions, and a message box to its mailbox or its prompt.

Only agents write tasks (`agentd task ...`, MCP `agentd_tasks_set`): the app never adds or edits
them. Hosts whose daemon has no board yet list their agentd sessions with status and preview.
Relay devices follow their scope: `view` reads the Panel but can not answer or write; questions
are only shown to owner devices (the daemon filters them). Push notifications are not part of
this screen yet.

## Relay hosts

1. On the host: `[relay] enabled = true` and `url = "wss://relay.example"` in
   `~/.config/agentd/config.toml`, then `agentd relay invite [--scope view|operate|admin]`.
2. On the phone: Hosts > + > **Invitación relay**, tap **Escanear QR** and point the camera at the
   QR that `agentd relay invite` prints, or paste the `agentd://relay?...` link (or open
   it on the phone: Android and iOS register the `agentd://relay` link), give the device a name,
   **Emparejar**, and approve on the host (`Approve? [y/N]`).
   The link may be pasted as the terminal shows it: the `Link:` prefix, the text after it and
   line wraps are ignored. A failed pairing stays on screen with its reason and a **Reintentar**
   button; "El host no está conectado al relay" means the host's daemon is not linked to the
   relay (`agentd relay status` on the host), so no invite can work until it is.
3. The host appears with a `relay` tag and its scope. Only agentd sessions are listed (no
   zellij/tmux/shells/provisioning/folder browser/image upload: those need a shell, SSH only).
   The UI follows the scope the host granted: `view` = read-only chat, approvals shown but not
   answerable, terminal observe only; `operate` = prompts, approvals, terminal control and mailbox;
   `admin` = also new sessions (alias or absolute folder, harness from the host's profiles) and
   Terminar. The daemon enforces the same rules.

Each pairing generates a new X25519 device key for that host (secure storage, never leaves the
phone); removing the host deletes it (revoke it on the host too: `agentd relay devices revoke`).
Protocol and code: `lib/src/relay/` (Noise IK / IKpsk2, stream mux, WebSocket), interop pinned by
the Go vectors in `test/relay/testdata/noise_vectors.json`. Optional live test:

```sh
AGENTD_RELAY_TEST_INVITE='agentd://relay?...' flutter test test/relay/ws_test.dart
```

(an invite from a throwaway daemon: `agentd relay invite --no-approve --scope admin`; the test
starts and removes a `sh` session).
