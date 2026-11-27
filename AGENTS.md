# agentd-app: guide for agents

Mobile Flutter client (Android and iOS only) for coding agents: work dashboard (Panel), sessions
inbox, chat view, terminal, approvals, agentd mailbox and host provisioning, over SSH or
agentd-relay. Humans: see `README.md`. Architecture and decisions: `docs/plan.md`.

## Layout

| Path | Content |
|---|---|
| `lib/main.dart` | entry point, real wiring or fakes (`AGENTD_APP_FAKE`) |
| `lib/src/core/contracts.dart` | the only cross-layer API: models and repository interfaces |
| `lib/src/transport/` | SSH (`RemoteShell`), key and host key stores, connection pool |
| `lib/src/relay/` | agentd-relay client: Noise, stream mux, WebSocket, pairing |
| `lib/src/agentd/` | daemon wire protocol: `AgentdClient` (ops), events, attach, mapping to contracts |
| `lib/src/mux/` | zellij and tmux adapters |
| `lib/src/provision/` | host detection and installs |
| `lib/src/car/` | Android Auto: `CarHub` (snapshot, voice reply, conclusion), `CarBridge` (channel `agentd/car`, engine body), text helpers |
| `android/app/src/main/kotlin/.../car/` | Android Auto native side: headless `CarEngine`, car app service and screens, messaging notifications, push receiver |
| `lib/src/data/` | real repositories (`AppData.create`): hosts, sessions, mail, board (with backlog notes), devices |
| `lib/src/ui/` | theme, providers, screens, widgets, `fakes/` (sample data of the mockups) |
| `test/` | mirrors `lib/src/`; `test/agentd/fake_daemon.dart` is the fake daemon |
| `scripts/release.sh` | build, check and publish the GitHub Release of a tag |
| `docs/` | `plan.md` (architecture, per-feature notes), `signing.md`, `push.md` (FCM, Firebase config), `android-auto.md` |

## Commands

```sh
export PATH=/apps/flutter/bin:$PATH
flutter analyze
flutter test
flutter run --dart-define=AGENTD_APP_FAKE=true   # in-memory sample data
flutter build apk --debug
```

On machines with Sluice, run the checks through its `verify` tool instead of the shell.

## Release

After pushing a `v*` tag, run `scripts/release.sh` (or `--dry-run` to build and check only): signed
split APKs in `dist/release-<version>/` (gitignored) published as the latest GitHub Release. The agentd
website matches the asset names `agentd-app-<version>-<abi>.apk` and `SHA256SUMS`: do not rename them.
The script refuses an untagged or dirty HEAD, a tag that differs from `pubspec.yaml` or is not on origin,
an existing release, and a missing `android/key.properties` (never ship debug-signed APKs). Publishing
is outward-facing: only with José's direct OK.

## Conventions

- English for code, comments, identifiers, docs and commits. UI copy in Spanish.
- Conventional commits; a `feat` bumps `version` in `pubspec.yaml`.
- Layers talk only through `core/contracts.dart`. New data for the UI = a contract type + a
  repository method, a real implementation in `data/`, a fake in `ui/fakes/` and a provider in
  `ui/providers.dart` (overridden in `lib/main.dart` and `test/ui/helpers.dart`).
- Wire models mirror agentd `internal/proto` field names; args sent are exactly the daemon's
  names (it rejects unknown fields). The protocol contract lives in the agentd repository
  (`AGENTS.md`, `docs/plans/`).
- The UI hides what a relay scope forbids (`HostConfig.canOperate`, `canAdmin`, `hasShell`);
  the daemon enforces it.
- Colors and fonts come from `ui/theme.dart` (`AppColors`, `AppFonts`, `AppText`); shared widgets
  from `ui/widgets/common.dart`. Touch targets are at least 44 px.
- QR scanning uses `mobile_scanner` (maintained, Android + iOS, CameraX / AVFoundation, no
  Firebase; Android keeps the bundled ML Kit barcode model so it works without Play Services).
  Camera code stays in `ui/screens/qr_scan_screen.dart`, behind `qrScannerProvider`; tests never
  open a camera.
- Every feature has tests: wire against `FakeDaemon`, repositories against `StubHosts` +
  `DataShell`, screens with `pumpUi` on the fakes.
- Update `README.md` and `docs/plan.md` in the same change.

## Do not

- Put logic in the Kotlin car screens: decisions (option matching, routing a reply) live in
  `lib/src/car/` where they are tested; Kotlin only draws the snapshot and forwards calls.

- Run real agent CLIs (claude, codex, pando...) or installers in tests.
- Log keys, passwords, invite codes or prompt text.
- Add desktop targets (the desktop client is a separate program in the agentd repository).
- Edit the agentd repository from here: ask its agent for daemon changes.
- Commit `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`,
  `lib/firebase_options.dart` or any Firebase/FCM key; log the FCM token. Firebase is only
  `firebase_core` + `firebase_messaging` for push (`docs/push.md`); tests use `NoopPushMessaging`.
- Let the app write agent tasks: only agents do (`tasks_set` / `task_update` are session-only).
  Assigning a backlog note (`note_assign`) is the one way a human adds a task, and the daemon does it.
- Point `AGENTD_TEST_SOCKET` (live tests) at the user's daemon: only at a throwaway one with its
  own `AGENTD_SOCKET`, `AGENTD_STATE_DIR` and `AGENTD_CONFIG`.
