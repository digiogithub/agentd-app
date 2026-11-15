# agentd-app

Mobile client (Android and iOS) for coding agents over SSH: one inbox of agent sessions across
hosts (agentd, zellij, tmux, plain SSH shells), chat view, terminal, approvals, the agentd
mailbox and host provisioning. The desktop client is a separate native app; this project has no
desktop targets.

SSH is the only transport: the app generates an ed25519 key on the device (secure storage),
trusts host keys on first use and talks to the agentd daemon through its unix socket over SSH.

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
