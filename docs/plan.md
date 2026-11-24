# agentd-app — plan

Mobile Flutter client (Android and iOS only) that joins what Moshi, Alma and agentd do:
one inbox of coding agents across hosts, chat view, terminal, approvals, agent mailbox,
and host provisioning over SSH (agentd sessions also through agentd-relay). Design (validated mockups):
https://claude.ai/artifact/T3omboYBBsufo6zJHQpZdP. Background analysis:
`/www/MCP/herdr-movil/{moshi-hook,alma-desktop,ideas-agentd}.md`.

## Architecture decisions

- **Mobile only.** Android + iOS. The Linux/macOS targets were removed (decision by José,
  2026-11-15): the desktop app is a separate native Go program built in the agentd repo.
  Do not add desktop platform folders or desktop-only code paths here.

- **SSH is the main transport.** No gateway, no tokens, no open ports.
  `dartssh2` (pure Dart). Ed25519 key generated on the device, kept in
  `flutter_secure_storage`; host key trust on first use (SHA256 fingerprint shown).
- **agentd**: the app opens `direct-streamlocal@openssh.com` to the daemon socket
  (`$XDG_RUNTIME_DIR/agentd/agentd.sock`, fallback `/tmp/agentd-$UID/agentd.sock`) and speaks
  the daemon wire protocol (newline JSON ops, binary attach frames; see agentd `AGENTS.md`
  "Wire protocol" and `internal/proto`). The daemon sees the sshd child as `human:<user>`
  (uid check + ancestry), so every human op works: `ls`, `view`, `act`, `subscribe`, `send`,
  `inbox`, `queue`, `run`, `attach`. If the socket cannot be opened, fall back to the `agentd`
  CLI with `--json` over exec.
- **zellij / tmux**: detection and listing over exec (`zellij list-sessions -n`,
  `tmux list-sessions -F`), terminal = PTY running `zellij attach` / `tmux attach`. No chat view
  (screen only) for them.
- **Provisioning**: detect (one script, sectioned output), install agentd from the GitHub release
  (`digiogithub/agentd`, checksum verified), `systemctl --user enable --now agentd`,
  optional `[herdr] listen`, `agentd mcp install`, CLIs via npm/release. Every command is shown
  before it runs.
- State: `flutter_riverpod`. Terminal widget: `xterm`. Fonts: `google_fonts` (Inter, JetBrains Mono).
- Flutter 3.50: material is `package:material_ui/material_ui.dart`.

## Layers (`lib/src/`)

Cross-layer API: `core/contracts.dart` only.

| Folder | Owner phase | Content |
|---|---|---|
| `core/` | P0 | contracts, ids |
| `transport/` | P1-A | `SshRemoteShell implements RemoteShell`, key store, host key store, connection pool |
| `relay/` | R | agentd-relay client: Noise IK/IKpsk2 (`noise.dart`), stream mux (`mux.dart`), WebSocket (`msg_conn.dart`), invite + payloads (`wire.dart`), pair/connect/dialer (`client.dart`) |
| `agentd/` | P1-B | wire codec, `AgentdClient` (ops), event subscription, attach frames, model mapping to contracts |
| `mux/` | P1-C | zellij and tmux adapters over `RemoteShell` |
| `provision/` | P1-C | `ProvisionService` implementation, detect script + parser |
| `ui/` | P1-D | theme, screens, widgets, fakes (`ui/fakes/`) |
| `data/` | P2 | real repositories wiring transport + agentd + mux + provision (`AppData.create`), the board repository |

## Phases

- [x] P0 scaffold: project, deps, contracts, plan.
- [x] P1 (parallel): A transport, B agentd client, C mux + provision, D UI on fakes. Each with
  unit/widget tests, `dart analyze` clean.
- [x] P2 integration: `data/` repositories, Riverpod providers, app boots on real repos, fake
  mode flag for demos (`--dart-define=AGENTD_APP_FAKE=true`).
- [ ] P3 field test against a real host (agentd + zellij), Android and iOS builds.
- [x] R relay transport (agentd plan phase 5): Dart Noise + mux + WebSocket, pairing by invite
  link, relay hosts in the inbox, scope-aware UI. See "Relay transport" below.

## Integration (P2) notes

- Contracts added in P2: `HostsRepository.shell` / `enrollWithPassword`, `HostKeyPrompts`
  (TOFU channel between the SSH layer and the UI dialog), `PendingInteraction.kind/detail`,
  `SessionOption.kind/checked`, `SessionSource.shell`, `SessionsRepository.projects`,
  `ChatItem.meta`, `ProvisionEvent.skipped`, `PlannedStep` + `ProvisionService.planSteps`.
- `data/hosts_repository.dart`: hosts in shared_preferences (`agentd.hosts.v1`), secrets only in
  the secure store, one pooled SSH connection per host, detect after connect, reconnect with
  backoff after a lost connection. Password auth is a one-time bootstrap: the app's ed25519
  public key is appended to `~/.ssh/authorized_keys` (idempotent, 0700/0600) and the host is
  saved as `generatedKey`; the password is never stored.
- `data/sessions_repository.dart`: per host one `subscribe` stream (snapshot + events); views
  fetched on demand (`view` with `since_revision`), short views for waiting sessions so the inbox
  cards have their classified question; zellij/tmux polled every 5 s while the list is watched;
  SSH login shells (`SessionSource.shell`) kept in memory with a replay buffer, listed while their
  PTY is open. agentd attach is `passive` with 2000 lines of history.
- `data/mail_repository.dart`: own inbox + peek (`inbox as`) at every session mailbox + work
  queue items, polled every 5 s with `since_digest`.
- Pending kinds (`agentd/mapping.dart` `classifyPending`): the daemon reports no kind for screen
  dialogs, so the app derives permission / plan / question from the dialog text and labels
  (Claude Code tool headers, Codex `$ cmd` lines, "don't ask again", "keep planning"); an OSC 7501
  `program_status.kind` wins when the session reports one.

- [x] Panel (agentd AGED-US-0046, epic AGED-EP-0007): work dashboard tab. See "Panel" below.

## Rules

- English for code, comments, identifiers. UI copy in Spanish (l10n later).
- No real agent CLIs (claude, codex, pando) in automated tests.
- Never log keys, passwords or prompt text.

## Dictation

Chat composer dictation (`lib/src/ui/widgets/dictation/`): `DictationService` (speech_to_text behind an interface, overridable through `dictationServiceProvider`), `DictationButton` (tap = start/stop, long-press = cancel; partial text is spliced live at the cursor by the pure `DictationSplice`), language from the "Dictado" setting (`dictationLocaleProvider`, kept in shared_preferences; automatic = device locale if the recognizer supports it, else `es_ES`). Transcribed text is never logged. Android needs Google speech services (RecognitionService); iOS Speech needs a real device.

## Images

The composer's "+" attaches up to 6 images (`widgets/attachments/`): gallery (multiple) or camera through `image_picker` (scaled to 2048 px, quality 85) behind `AttachmentSource` (`attachmentSourceProvider`, faked in tests). Tapping a thumbnail opens `screens/image_editor_screen.dart` on the ORIGINAL image: pen, arrow, rectangle, text, 5 colors, thin/thick stroke, undo/redo/clear. Marks live in image space (`ui/annotate/annotation_model.dart`, pure Dart; painter in `annotation_painter.dart`), so "Listo" flattens them to a full-resolution PNG (`renderAnnotatedPng`); the model is kept per attachment to reopen the editor. On send each image is uploaded with `SessionsRepository.uploadImage` (`RemoteShell.writeFile`: SFTP, falling back to `base64 -d`/`-D` over exec) to `${XDG_CACHE_HOME:-$HOME/.cache}/agentd-app/uploads/<session>/<yyyyMMdd-HHmmss>-<n>.<ext>` (dir 0700, file 0600), then ONE prompt is sent: the text, a blank line and one absolute path per line (`composePrompt`). On failure attachments and text stay (uploaded paths are reused on retry). Remote files are not deleted by the app yet (the cache dir can be cleaned by hand). Chat tab only: agentd sessions.

## Theme

Dark, light and system (`ThemeChoice` in Ajustes > Apariencia). `ui/theme.dart`: `AppPalette` (const `dark` = the mockup values, `light`; `AppPalette.resolve(choice, platformBrightness)`), and `AppColors.x` are static getters over `AppColors.palette`, so call sites stay `AppColors.x` but cannot be `const`. The root `AgentdApp` sets the palette (on first build, on a setting change and on `didChangePlatformBrightness`), builds `ThemeData` from it, sets the system bar style, and after a change marks every element dirty so the whole tree repaints without losing state or routes. Never cache colors or TextStyles in `static final`/top-level variables: use getters. Not themed: the terminal (xterm `terminalTheme` and `terminalBg` stay dark in both modes), the annotation mark colors (`AnnotationColors`), and the Android/iOS launch screens. Tests: `test/ui/theme_test.dart`.

## Chat tables, links and send errors

`ui/chat/table_parser.dart` (pure Dart): `parseChatSegments(text)` splits an agent item into text and table segments. It handles Claude Code box-drawing tables (light, heavy, double, rounded; indentation and a `⏺` prefix tolerated; column bounds from `┬┼` positions; cell fragments of one row joined with a space; header = first row when an inner separator follows; without separators between body rows a line with an empty first cell continues the previous row) and markdown pipe tables (separator row required). Inconsistent column counts = no table: the lines stay plain text. `chat_table_view.dart` renders a table (bold header on `raised`, palette borders, columns 80..260 wide, horizontal scroll, long-press a cell or "Copiar tabla" copies). `links.dart`: `findUrls` (http/https, trailing punctuation trimmed unless parens balance) and `urlLauncherProvider` (url_launcher, `LaunchMode.externalApplication`; overridden in tests); `linkified_text.dart` renders `code` + links for user and agent text. Android `<queries>` has a VIEW/https intent and iOS `LSApplicationQueriesSchemes` has `https`. Send failures map `AgentdError.code` to a Spanish toast (`sendErrorMessage` in `chat_tab.dart`). Tests: `test/ui/chat/`.

## Chat selection, tool grouping and code blocks

Same rules as agentd-desktop AGED-US-0051 (agentd commit `17215a3`, `internal/desktopui/app/session/chat.go`
`Items`); its two tests are ported in `test/agentd/mapping_test.dart`. Added on 2026-11-23, version 1.4.0.
No daemon contract change: the app reads one more optional field.

- **Selection**: `ChatTab` wraps the chat `ListView` in a `SelectionArea`: long-press selects, handles
  extend across paragraphs and entries, the platform toolbar copies. The question card and the copy
  button of a code block are `SelectionContainer.disabled`. With a selection up, the first tap only
  dismisses it. A table cell keeps its own long-press (copy the cell). Entries scrolled far out of
  the list are not part of a selection (the list builds lazily). The composer is a plain `TextField`:
  paste always worked.
- **Wire**: `AgentdViewLine.code` (JSON `code: true`, view `markup: true`, agentd 0.8.2 or later;
  absent = false, so older daemons give no code blocks). A code line has no `md`.
- **Parser** (`agentd/mapping.dart` `chatItemsFromLines`):
  - Tool header: a bullet line whose `md` starts with a bold run followed by `(` or by nothing
    (`_boldCall`: `**Bash**(go test`, `**Read**`, `**agentd - agentd\_inbox (MCP)**(all: true)`).
    Fallback without `md`: `Name(args` (closing parenthesis optional) and the codex verbs. A code
    line is never a header.
  - Under a tool header, indented lines continue the call until the output mark (`⎿`, codex `└`);
    from there they are output. Blank lines do not end the item; only a line at the left margin
    does. `ChatItem.title` = tool name, `text` = call arguments then output, `meta` = first output
    line.
  - Indented lines after a prompt marker belong to that user item.
  - A turn end note (`✻ Brewed for 8s`, `_turnEnd`) is a system item.
  - A run of code lines becomes one block between `kChatCodeFence` lines (four backticks, in
    `core/contracts.dart`) inside the agent item: text minus the bullet, or minus at most two
    leading spaces. A blank line followed by code stays in the block; a non-code line right under
    code (a lone `}`) belongs to it; a blank line followed by prose closes it.
- **Rendering**: `parseChatSegments` yields `CodeSegment` (also for a block still open); `ChatCodeBlock`
  (`ui/chat/chat_table_view.dart`) draws it monospace, no markup, horizontal scroll, `Copiar código`.

## Projects, terminal only, folder browser, terminate

Spec: `agentd/docs/plans/agentd/workspace-ux_plan.md` (same behaviour on the desktop client).

- **Agents by project**: toggle `Proyecto | Estado` (`AppSettings.agentsGrouping`, JSON key `agentsGrouping`, default project; old stored settings parse to the default). `format.dart` `groupByProject`: key = host + `cwd` (else the project name, else `Sin proyecto`); label = path with the home shown as `~` (`shortPath`, guessed from `/home/<u>`, `/Users/<u>`, `/root`; agentd alias names are not used for labels). Order inside a group: needs answer, working, rest by last update; groups by attention then recent activity. Header: label, host name when more than one host, count, attention badge and `+` (New session with host and project prefilled: `NewSessionScreen(hostId, project)`).
- **New session**: `Abrir: Agente | Solo terminal` (`OpenKind`); the old `bash` agent tile is gone. Terminal only passes `harness: kShellHarness` to `SessionsRepository.launch`: agentd `run {target, harness: "shell", cmd: ["sh","-c",'exec "${SHELL:-sh}" -l'], profile: "default"}` (profile `shell` if the daemon has one; name `shell@<label>`), zellij/tmux a pane/window with no command (adapters accept an empty command), SSH `cd` + login shell. Project field: alias chips, `+ Carpeta…` (free text) and `Explorar…`.
- **Folder browser**: `SessionsRepository.listDir(hostId, path, {hidden})` runs one POSIX sh script (`data/list_dir.dart`, path single-quoted, NUL separated output, flag 1/0 for readable+traversable, cap 2000, exit 3 = `No existe`, 4 = `Sin permiso`) over the host shell; the parser is pure Dart. `screens/folder_browser_screen.dart` is a full-screen route (breadcrumb up to `/`, Inicio, Subir, Mostrar ocultas, greyed locked folders, `Usar esta carpeta`). Tests run the script under real `sh` (`test/data/list_dir_test.dart`).
- **Terminate**: `SessionsRepository.terminate(s)`: agentd `kill KILL`, poll `ls` until exited (5 s), `rm` (exited: only `rm`); zellij `kill-session` + `delete-session --force`; tmux `kill-session`; SSH shell closes its PTY. UI (`ui/terminate.dart`): `Terminar` in the session screen menu and long-press on a list row, confirm dialog, then back to the list.

## Broadcast prompt (selection mode of the Agents list)

Same feature as agentd-desktop AGED-US-0050 (agentd `docs/plans/agentd/broadcast-prompt_plan.md`).
Client only: no contract, wire or daemon change. Added on 2026-11-22, version 1.3.0.

- State lives in `_AgentsScreenState` (`ui/screens/agents_screen.dart`): `_selecting`, `_picked`
  (session keys), `_draft`, `_sending`, `_sendError`. Leaving the mode clears the selection.
- Selectable (`_pickBlock` returns null): agentd source, status not `exited` / `starting`,
  `HostConfig.canOperate`. Other rows render as a disabled `PickRow` (`ui/widgets/session_card.dart`)
  with the reason.
- Quick picks (`pick-all`, `pick-host:<id>`, `pick-none`) work on the sessions shown, so the
  filter chips and the search apply. Host picks appear with two or more hosts.
- `_sendAll`: `SessionsRepository.prompt` per target with `Future.wait` (parallel). The
  repository already forces only while the session is `working` and sends no `revision`.
  Delivered sessions are unselected and counted in a toast; refused ones stay selected and are
  named in the bar with the cause of the first refusal (`sendErrorMessage`). All delivered =
  draft cleared (when unchanged) and mode off.
- Mobile layout: the composer is a bar docked under the list and replaces the `Nueva sesión`
  FAB while the mode is on; the quick picks are a horizontally scrolling row under the filters.
- Tests: `test/ui/broadcast_prompt_test.dart` (`FakeSessionsRepository.promptErrors` fails
  single sessions).

## Relay transport (agentd-relay)

Protocol v1 and design live in agentd: `docs/plans/agentd/relay_plan.md` (normative) and
`docs/design/relay-transport.md`; the Go reference is `internal/relaywire` + `internal/relayclient`.

- **Crypto**: package `cryptography` 2.9.0, its synchronous pure-Dart primitives (X25519,
  ChaCha20-Poly1305, SHA-256; HMAC/HKDF written on top per the Noise spec). `IkHandshake` does
  both roles (the responder is used by tests); psk placement 2 mixes every `e` into the chaining
  key. Nonce = 4 zero bytes + 64-bit little-endian counter. `test/relay/noise_vectors_test.dart`
  reproduces the Go vectors byte for byte (msg1, msg2, one transport message each way, initiator
  and responder, IK and IKpsk2).
- **Mux** (`RelayMux`, `RelayStream implements ByteChannel`): odd stream ids from 1, DATA <= 32
  KiB, 256 KiB window per direction, CREDIT granted once the listener consumed >= 64 KiB (a paused
  subscription holds credit back), a window overflow by the peer breaks the tunnel. `close()` sends
  bytes still waiting for credit first, then CLOSE. `AgentdClient` runs on these streams unchanged
  (ops, subscribe, attach).
- **WebSocket**: dart:io `WebSocket.connect(<relay>/v1/connect?route=…, protocols:
  ['agentd-relay.v1'])`, ping every 25 s, binary messages <= 70 KiB. Close codes 4404 host offline,
  4504 host did not answer, 4429 rate limited, 4503 too many tunnels (`RelayFailure`; Spanish text
  in `describeRelayError`).
- **Model**: `HostConfig.transport` (`ssh` | `relay`) + `RelayHostInfo` (relay URL, route, pinned
  host key, device id, scope, sessions, kind, label; JSON in the same `agentd.hosts.v1` list).
  `canOperate` / `canAdmin` / `hasShell` drive the UI. Contract additions: `HostsRepository.pairRelay`
  (+ `RelayPairPhase`) and `agentdChannel`.
- **Keys**: one X25519 device key per paired host (decision: revoking or removing one host never
  touches another, and hosts cannot correlate the phone across them), secure store slot
  `agentd.relay.key.<keyId>`; the invite code is used once and never stored.
- **Data**: `SshHostsRepository` keeps one `RelayDialer` (tunnel) per relay host; a new tunnel
  marks the host online with `relayCapabilities` (agentd only, socket `relay`) and refreshes the
  scope from the Welcome (a downgrade on the host shows up at the next connect); a dropped tunnel
  marks it offline and reconnects with the usual backoff; `reconnectAll` pings the live tunnel.
  `shell()` throws `NoShellOverRelay`. `AgentdClients` dials `agentdChannel` for relay hosts. The
  mail poller treats `forbidden` queue / mailbox ops as empty (queues are never exposed over the
  relay; guests have no mailbox). Launch over the relay: harness only (no plain terminal), target
  = alias or absolute path.
- **UI**: Añadir host has `SSH | Invitación relay` (paste, device name, "Aprueba en el host" while
  the host waits); `agentd://relay` links open it (app_links; Android intent filter, iOS URL scheme;
  Flutter's route deep linking is off). Hosts list: `relay` + scope tags, offline reason. Session
  screen / agents list / new session hide what the scope forbids (`hostConfigProvider`).
- **Invite text** (2026-11-24): `relayLinkCandidates` (`core/contracts.dart`) finds the link in
  pasted or scanned text: text around it (`Link:  agentd://...`), an upper-case scheme, and
  terminal line wraps (the following lines that hold only link characters are joined; the first
  line alone is the second candidate). `RelayInvite.parse` validates the candidates in order, so
  the fixed-length fields (route, keys, invite id) decide. The invite field is multi-line so a
  system paste keeps the line breaks. Bug fixed: the form refused anything that did not start with
  `agentd://relay?`, which is what a line copied from `agentd relay invite` (`Link:  ...`) is.
- **Pairing errors**: a failed pairing is an inline box (`relay-pair-error`, reason +
  `pairErrorHint`) and the button becomes "Reintentar"; the link stays in the field. A host that
  is not linked to the relay answers at once (the relay closes the tunnel with 4404 =
  `RelayFailure.hostOffline`); the relay dial and the handshake have 15 s and 20 s timeouts.
- **Tests**: vectors, mux (window, credit, close, limits, tunnel drop), invite parser, client
  against an in-memory fake host that follows the protocol (`test/relay/fake_host.dart`), a
  loopback WebSocket server, the repository (`test/data/relay_hosts_test.dart`), UI
  (`test/ui/relay_ui_test.dart`). `AGENTD_RELAY_TEST_INVITE` runs a live test against a real relay
  + daemon (done on 2026-11-19 against the Go `agentd-relay` and daemon from the agentd working
  tree: pair, ping, run, ls, attach observe, kill, rm all passed).
- **QR scan** (2026-11-24): "Escanear QR" in both forms of Añadir host opens
  `screens/qr_scan_screen.dart` (`mobile_scanner`, QR format only). The screen ignores codes that
  hold no `agentd://relay` link (it says so) and pops with the text of the first invite; the form
  puts it in the invite field, so it follows the path of a pasted link (`relayLinkCandidates` +
  `RelayInvite.parse`) and the user still confirms the device name before "Emparejar". The scanner
  is behind `qrScannerProvider` (tests override it; `QrScanScreen.preview` replaces the camera).
  Camera failures (permission denied, no camera) are a Spanish text that offers the paste. Android:
  `CAMERA` permission, camera feature not required, bundled ML Kit model (no Play Services download,
  a few MB more); iOS: `NSCameraUsageDescription`. The scanned text is a secret: never logged.

## Paired devices (Ajustes > Dispositivos)

2026-11-24, version 1.7.0; contract in agentd `docs/plans/agentd/backlog-notes_plan.md`, section
"Relay devices". Relay devices may use the op from agentd 0.9.0 (before it, `forbidden`).

- **Wire**: op `relay {action: "devices"}` → `devices[]` (`AgentdRelayDevice`: id, name, platform,
  scope, sessions, kind, created_at, expires_at, last_seen, online; invites are ignored) and
  `relay {action: "revoke", device: <id>}`. Humans on the socket (SSH) and owner admin relay devices
  that are not session-limited get every device; any other relay device gets its own entry and may
  revoke only itself (`forbidden` otherwise).
- **Contracts**: `PairedDevice` (`isThisDevice` = the id of `RelayHostInfo.deviceId`),
  `DevicesRepository` (`devices`, `revoke`), `DevicesException`, `HostConfig.canManageDevices`.
- **Data** (`data/devices_repository.dart`): this device first, then the connected ones, then by
  name. A self revoke removes the host from the app after the daemon's answer (the daemon closes
  the tunnel about 300 ms later and refuses the device from then on; `HostsRepository.remove`
  also deletes the device key). A failed revoke keeps the host.
- **UI**: `screens/devices_screen.dart`; a confirmation before every revoke, with its own text for
  this device (access lost, host removed, pair again). `devicesProvider` has no automatic retry
  (the error state has "Reintentar") and is invalidated after a revoke. The settings section lists
  online hosts with an agentd socket.
- **Tests**: `test/data/devices_repository_test.dart`, `test/ui/devices_screen_test.dart`,
  and the devices case of `test/agentd/live_notes_test.dart`.

## Panel (work dashboard)

Mobile side of the agentd work dashboard (agentd `docs/plans/agentd/dashboard_plan.md`, normative
contract; story AGED-US-0046, 2026-11-22). Design: canvas
https://claude.ai/artifact/187awNfuofy4KQZ2zYBLSG (Panel, answer sheet, agent tasks).

- **Wire** (`agentd/`): ops `board {since_digest?}` and `tasks {name}`; `reply {notify?}`;
  `Message.kind / options / task`; event `task.changed` (`TaskChangedEvent`); `mail.*` events carry `kind`;
  `SessionInfo.tasks` summary. `reply` already existed. The app never sends `tasks_set` /
  `task_update` (session-only ops) and never sends `kind: "question"`.
- **Contracts**: `AgentTask`, `AgentQuestion`, `BoardSession`, `HostBoard`, `BoardRepository`
  (`watch(hostId)`, `answer(hostId, questionId, body, {notify})`).
- **Data** (`data/board_repository.dart`): one `board` call per host, then its own `subscribe`
  with `kinds: [session, status, attention, mail, task]`; every such event schedules a debounced
  (250 ms) `board` with `since_digest` (`not_modified` emits nothing). The subscription opens only
  after a first successful board, so a daemon without the op (before 0.8.0) is never sent the
  `task` kind: its board is `available: false` and asked again every 20 s. Nothing runs while
  nobody listens.
- **Terminal menus** are not in the board: the Panel joins `AgentSession.pending` of the sessions
  repository (classified view, revision + epoch) with the board by host + name.
- **UI**: `ui/panel_model.dart` (pure: waiting items, counters, agent order), `screens/
  panel_screen.dart`, `screens/panel_sheets.dart` (question sheet, menu sheet),
  `screens/panel_agent_screen.dart`, `widgets/panel_widgets.dart`. The bottom nav has five tabs:
  Panel, Agentes, Hosts, Buzón, Ajustes (the mockup drew four; Ajustes stays reachable).
- **Destinations**: Buzón = `reply` for a question, `send` to the session for a free message;
  Prompt = `act prompt` (forced while the agent works, as in the chat). Question options always
  answer by `reply`; the Buzón / Prompt toggle is for free text. A question answered through the
  prompt is then closed with `reply {notify: false}` (agentd AGED-US-0049: stored as delivered,
  never injected); if that reply fails (a daemon without `notify`) the prompt result is kept and
  a toast says the question is still open.
- **Backlog notes** (2026-11-24; agentd `docs/plans/agentd/backlog-notes_plan.md`, normative;
  version 1.6.0; needs agentd 0.9.0). Wire: ops `notes {states?, since_digest?}`, `note_add {title, body?}`,
  `note_update {id, title?, body?, state?: "open"}`, `note_rm {id}`,
  `note_assign {id, session, status?: in_progress, notify?: false}` (defaults are not sent), event
  `note.changed` (`NoteChangedEvent`, no session), `Task.origin` (`AgentTask.fromBacklog`).
  Contracts: `BacklogNote`, `NoteState`, `HostBoard.notes` / `backlog`, `BoardRepository.addNote /
  updateNote / removeNote / assignNote`, `BacklogException` (`BacklogFailure`),
  `HostConfig.canBacklog` (SSH, or an owner relay device with operate and no session globs).
  Data: the notes travel with the board (`_fetchNotes`, their own digest) and never take it down:
  `invalid` (an agentd before the backlog: unknown op) or `forbidden` = no section and not asked
  again for that client; `not_ready` is asked again at the next refresh. The subscription adds the
  `note` kind only after op notes answered (an older daemon refuses unknown kinds) and is reopened
  when that changes. UI: `screens/panel_backlog.dart` (`BacklogSection` per host after "Agentes",
  note sheet, assign sheet with the board's sessions of that host and Pendiente / En curso; done
  notes behind "N notas hechas"). The app never writes tasks itself: `note_assign` makes the daemon
  add the task. Tests: `test/agentd/notes_test.dart`, `test/data/board_repository_test.dart`
  (group backlog notes), `test/ui/panel_backlog_test.dart`; `test/agentd/live_notes_test.dart` runs
  against a throwaway daemon (`AGENTD_TEST_SOCKET`, passed on 2026-11-24 against agentd 8b9e817).
- **Relay**: `board` and `tasks` are allowed to every scope; `canOperate` hides the answer
  controls for `view` devices; guests get no questions from the daemon.
- **Fakes**: `sampleBoards` puts the mockup's plans on the sample sessions
  (`FakeBoardRepository`). Tests: `test/agentd/board_test.dart`,
  `test/data/board_repository_test.dart` (fake daemon), `test/ui/panel_screen_test.dart`.
- Not done: push notifications (AGED-US-0047 / 0048, through agentd-relay), the unread mail
  count of the board (`HostBoard.unreadHuman` is carried but not drawn).
