# agentd-app — plan

Mobile Flutter client (Android and iOS only) that joins what Moshi, Alma and agentd do:
one inbox of coding agents across hosts, chat view, terminal, approvals, agent mailbox,
and host provisioning over SSH. Design (validated mockups):
https://claude.ai/artifact/T3omboYBBsufo6zJHQpZdP. Background analysis:
`/www/MCP/herdr-movil/{moshi-hook,alma-desktop,ideas-agentd}.md`.

## Architecture decisions

- **Mobile only.** Android + iOS. The Linux/macOS targets were removed (decision by José,
  2026-11-15): the desktop app is a separate native Go program built in the agentd repo.
  Do not add desktop platform folders or desktop-only code paths here.

- **SSH is the only transport and the only auth.** No gateway, no tokens, no open ports.
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
| `agentd/` | P1-B | wire codec, `AgentdClient` (ops), event subscription, attach frames, model mapping to contracts |
| `mux/` | P1-C | zellij and tmux adapters over `RemoteShell` |
| `provision/` | P1-C | `ProvisionService` implementation, detect script + parser |
| `ui/` | P1-D | theme, 9 screens, widgets, fakes (`ui/fakes/`) |
| `data/` | P2 | real repositories wiring transport + agentd + mux + provision (`AppData.create`) |

## Phases

- [x] P0 scaffold: project, deps, contracts, plan.
- [x] P1 (parallel): A transport, B agentd client, C mux + provision, D UI on fakes. Each with
  unit/widget tests, `dart analyze` clean.
- [x] P2 integration: `data/` repositories, Riverpod providers, app boots on real repos, fake
  mode flag for demos (`--dart-define=AGENTD_APP_FAKE=true`).
- [ ] P3 field test against a real host (agentd + zellij), Android and iOS builds.

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
