# Push notifications (FCM)

The hosts' daemons send the pushes themselves (agentd 0.10.0, `[push]` in the daemon config, contract
in the agentd repository: `docs/plans/agentd/push-fcm_plan.md`). The app registers its FCM token on
every agentd host it connects to and routes the taps. Only blocking items are pushed by default: an
`agentd ask` question to the human and an agent permission dialog.

## Firebase config: never in git

This repository is public (MIT). The Firebase config of the Android app,
`android/app/google-services.json`, is gitignored (as are `ios/Runner/GoogleService-Info.plist` and
`lib/firebase_options.dart`). Without it the app builds and runs normally, without push: the
`com.google.gms.google-services` Gradle plugin is applied only when the file exists, and
`Firebase.initializeApp()` failing turns push off.

Push works with the Firebase project of whoever builds the app; that project's service account key
goes to the daemons (`[push] credentials_file`). Another agentd user builds with their own project.

### Getting the file

- From the Firebase console: Project settings > Your apps > the Android app `es.digio.agentd` >
  `google-services.json`, saved as `android/app/google-services.json`.
- Or with the Firebase CLI (logged in as a member of the project):

  ```sh
  firebase apps:list ANDROID --project <project-id>
  firebase apps:sdkconfig ANDROID <app-id> --project <project-id> -o android/app/google-services.json
  ```

  First time only, to register the app: `firebase apps:create ANDROID agentd --package-name es.digio.agentd --project <project-id>`.

### CI

A build job restores it from the repository secret `GOOGLE_SERVICES_JSON` (the file in base64):

```sh
# once, by a maintainer
base64 -w0 android/app/google-services.json | gh secret set GOOGLE_SERVICES_JSON --repo digiogithub/agentd-app

# in the workflow, before flutter build
echo "$GOOGLE_SERVICES_JSON" | base64 -d > android/app/google-services.json
```

The file holds the project's public client config (API key restricted to the app, project number,
app id), not a server credential; it stays out of git anyway so that forks use their own project.

## App side

- `platform/push.dart`: `FirebasePushMessaging` (token, refreshes, taps; never logs the token).
- `data/push_repository.dart`: ops `push_register {token, platform, name, host_ref}` and
  `push_unregister {token}`; `host_ref` is the saved host id. A daemon without the op, a guest device
  or an unreachable host is ignored silently.
- `ui/push_controller.dart`: registers on every online agentd host (again after a reconnect and on a
  token refresh), unregisters when Ajustes > **Notificaciones push** is turned off or a host is
  removed. A push received in the foreground shows nothing (the Panel is live) and reconnects the
  hosts. A tap on `question` opens the Panel; any other reason opens that session's chat.
- Android: channel `agentd_attention` ("Decisiones pendientes", high importance) created in
  `MainActivity`, set as the FCM default channel in the manifest; Android 13+ asks for the
  notification permission the first time push is on.
- Android data mode (agentd `[push] android_mode`, or `push_register {mode: "data"}` which the app
  sends when the daemon lists `data` in `modes`): the app draws the notification itself (reply by voice,
  Android Auto) and removes it on a `resolved` push. See `docs/android-auto.md`.
- iOS: not configured yet (no `GoogleService-Info.plist`, no APNs key); the app runs without push there.
