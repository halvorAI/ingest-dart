# Changelog

## 0.1.0-dev.2

- `HalvorFlutter.start`: device-signed, backend-forwarded delivery for iOS and Android. The app never holds an API key.
- Device keys in secure storage (`SecureKeyStore`): iOS Keychain this-device-only, Android Keystore-backed. A fresh install replaces a key a previous install left in the Keychain.
- Registration through your backend's provisioning route (`{"public_jwk", "name"}` → `{"source_id"}`), retried with backoff and on return to the foreground; events emitted meanwhile wait with their context.
- `FileSpool`: undelivered batches on disk, at most 5 MB and 7 days, written atomically.
- Flushes when the app goes to the background; retries when it comes back.
- `debugApiKey`: straight to the sandbox from debug builds only, with `hk_test_` keys only.
- `resetIdentity()` for account deletion.

Fixes from the core review:
- `resetIdentity()` discards delivery and waits for it to stop, so nothing signed with the old key is sent or spooled afterwards.
- Events that waited for registration are sent in exactly the context they were emitted in, not one leaked from where registration finished.
- A registration that completes after `close()` is still saved, so the next start doesn't register the key again.
- `provisionUrl`, `forwardUrl` and `debugEndpoint` must be https (loopback http allowed). A `debugEndpoint` given as a full `/v1/events` URL registers at `/v1/sources`.
- `start()` initializes the Flutter binding itself, so it works before `runApp`.
- `resetIdentity()` waits for a registration under way, so no new key is left behind.
- `FileSpool` removes temp files a crash left behind.

Following HalvorAI's shared SDK behaviour (ape-schema `docs/SDK.md`), through `halvorai_ingest` 0.1.0-dev.2:
- Spool files are named `halvor-spool-<epoch ms>-<hex>.jsonl`, the format every SDK shares, and batches refused for good go to `dead/`.
- Events missing from a response count as accepted (with a one-time warning), and an event's own `environment` is kept.
- `HalvorFlutter` is a `HalvorEmitter`, so it can be given to `HalvorX402Client` to record x402 payments.
- Going to the background spools a batch that fails at once instead of retrying it in memory. Found on the iOS simulator: with the backend down, an app killed within the minute of retries lost the payment event.
- Going to the background also covers a request that hangs: what is in memory is on disk before it is sent, and a send already under way is given up on. Until now the batch stayed in memory for up to the 30-second timeout.
- `FileSpool.write` returns the new entry's id.
- `example/`: a runnable app with a demo backend, and integration tests for real devices.
