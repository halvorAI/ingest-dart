# HalvorAI Flutter example

An app whose agent pays, with each payment recorded as an event signed by a key that lives only on this device. It talks to a demo backend on your machine, so no API key is needed.

## Run it

1. **Start the demo backend.** It has the two routes the app calls (built with `@halvorai/ingest/device`) and a fake HalvorAI behind them that verifies every signature:

   ```bash
   cd backend && npm install && npm start
   ```

   Until `@halvorai/ingest` 0.4.0 is on npm, install it from a local checkout of [ingest-js](https://github.com/halvorAI/ingest-js) instead: `npm install --no-save jose ../path/to/ingest-js` (after `npm run build` there).

2. **Run the app** on the iOS simulator or an Android emulator:

   ```bash
   flutter run
   ```

   On an Android emulator, first run `adb reverse tcp:8787 tcp:8787`, so the app reaches the backend at `localhost`. The SDK allows plain `http` only for this machine; anything else must be https.

## Things to try

| Button | What happens |
| --- | --- |
| **Pay $12.99** | One `payment.settled` event, attributed to the demo agent and user through `withAgentContext`, signed on the device and forwarded through the backend. |
| **Pay with x402** | A purchase from the backend's pretend x402 endpoint through `HalvorX402Client`. It records `payment.requested`, `payment.authorized` and `payment.settled`, linked together. |
| **Backend: online/offline** | Takes event delivery down. Pay, then leave the app: the batch is written to the spool on disk at once. Kill the app, bring the backend back, and reopen it: the batch is sent. |
| **Reset identity** | Forgets the device key and the spool, and registers a new key, as for account deletion. |

The status card shows the SDK's counters and what the backend received and verified. `curl localhost:8787/admin/events` shows the events themselves.

To see a fresh install replace a key a previous install left behind (iOS keeps Keychain items when an app is deleted), delete the app and run it again: it registers a new key.

## Tests on a device

With the backend running:

```bash
flutter test integration_test -d <device id>
```

These run inside the app with the real secure storage, data directory and lifecycle. They cover:
- registration and signed delivery
- key reuse after a restart
- sending when the app goes to the background
- the spool across a restart
- the x402 flow
- identity reset

## Android backup

Android Auto Backup can copy app data to a new phone, but not the Keystore key that encrypts the stored device key. So a restored install should fail to read the old key, and the SDK then registers a new one. This is expected from how Keystore and `flutter_secure_storage` work, but not tested here: restoring a backup needs a Google account on the device. To keep the old encrypted value out of backups altogether, set `android:allowBackup="false"`, or exclude `FlutterSecureStorage` in your backup rules.
