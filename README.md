# agentd-app

Mobile client (Android and iOS) for coding agents over SSH: one inbox of agent sessions across
hosts (agentd, zellij, tmux, plain SSH shells), chat view, terminal, approvals, the agentd
mailbox and host provisioning. The desktop client is a separate native app; this project has no
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

## Relay hosts

1. On the host: `[relay] enabled = true` and `url = "wss://relay.example"` in
   `~/.config/agentd/config.toml`, then `agentd relay invite [--scope view|operate|admin]`.
2. On the phone: Hosts > + > **Invitación relay**, paste the `agentd://relay?...` link (or open
   it on the phone: Android and iOS register the `agentd://relay` link), give the device a name,
   **Emparejar**, and approve on the host (`Approve? [y/N]`).
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
