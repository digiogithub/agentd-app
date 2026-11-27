# Android release signing

Package name (Google Play): `es.digio.agentd`. Never change it after the first upload.

The app uses **Play App Signing**: Google keeps the app signing key; we sign uploads with our
**upload key**. A lost or leaked upload key can be reset from Play Console (Setup > App integrity),
so the upload key is not the end of the app, but keep it safe anyway.

## Upload key

- Keystore: PKCS12, alias `upload`, RSA 4096, valid until 2054, DN `CN=Digio, O=Digio, C=ES`.
- SHA-256 certificate fingerprint:
  `16:20:2B:D5:2C:F2:53:26:1E:67:D2:81:70:DF:C4:2A:49:D4:2B:E8:26:12:B1:DD:A7:8D:2A:F1:67:FC:F3:BB`
- The keystore and its password live outside the repository, on the build machine
  (`~/.android-signing/agentd-app/`, mode 0700). Keep a copy of both in the company password
  manager. They are never committed.

## Build configuration

`android/key.properties` (gitignored) points Gradle at the keystore:

```properties
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/absolute/path/to/upload-keystore.jks
```

`android/app/build.gradle.kts` signs release builds with it; without the file, release builds fall
back to the debug key (local testing only: Play rejects them).

```sh
flutter build appbundle --release          # build/app/outputs/bundle/release/app-release.aab (Play)
flutter build apk --release --split-per-abi  # sideload / GitHub release APKs
```

GitHub releases: `scripts/release.sh [--dry-run] [vX.Y.Z]` builds the split APKs of the tag on HEAD,
refuses without `key.properties`, checks the upload key fingerprint above with `apksigner` and
publishes `agentd-app-<version>-<abi>.apk` + `SHA256SUMS` as the latest release (the agentd website
links it).

Check a build: `apksigner verify --print-certs <apk>` or `keytool -printcert -jarfile <aab>` must show
the fingerprint above.

## First upload to Play Console

1. Create the app in Play Console (default language Spanish, app, free).
2. Release > Testing > Internal testing > Create release; accept Play App Signing (Google-generated
   key) and upload the `.aab`.
3. Fill the required store listing, content rating, data safety (the app stores SSH hosts and keys
   on the device and talks only to the user's own hosts) and privacy policy URL.
