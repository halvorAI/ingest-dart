# halvorai_ingest_flutter

Signed, attributed payment events for AI agents in Flutter apps. Each install signs its own events with a key kept in the platform's secure storage, and your backend forwards them to HalvorAI unchanged. **The app never holds an API key.** Like the core package, it is never in the payment path: `emit` returns at once and never throws.

> **Developer preview.** iOS and Android. Built on [`halvorai_ingest`](../halvorai_ingest), which it re-exports.

## How it works

```
App ──public key──▶ your backend ──POST /v1/sources──▶ HalvorAI      (once per install)
App ──signed events──▶ your backend ──unchanged──▶ HalvorAI /v1/events
```

1. On first start the SDK makes an Ed25519 key in secure storage and sends its public half to your backend, which registers it with HalvorAI and returns the `src_` id.
2. Events are signed on the device and posted to your backend. It checks that each event's owner is the signed-in user, then forwards the body byte for byte and returns HalvorAI's response.

The Node.js and Python server SDKs provide both routes as `registerDeviceSource` / `register_device_source` and `forwardEnvelopes` / `forward_envelopes`.

## Use

```dart
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';

final halvor = await HalvorFlutter.start(
  environment: Environment.live,
  provisionUrl: Uri.parse('https://api.example.com/halvor/sources'),
  forwardUrl: Uri.parse('https://api.example.com/halvor/events'),
  headers: () async => {'authorization': 'Bearer ${await session.token()}'},
  onError: (e) => debugPrint('halvor: $e'),
);

await withAgentContext(
  const AgentContext(
    agent: AgentRef(id: 'agt_travel_12', name: 'Travel booking agent'),
    owner: OwnerRef(id: 'own_u_4410', type: OwnerType.person),
  ),
  () async {
    // ... the agent pays ...
    halvor.emit(const EventInput.settled(
      payment: Payment(
        paymentId: 'pi_3QxAbCdEfGhIjKlM',
        amount: Amount.minor('41200', 'USD'),
        ref: StripeRef(paymentIntent: 'pi_3QxAbCdEfGhIjKlM'),
      ),
      payee: Payee.merchant(name: 'Example Airways'),
    ));
  },
);
```

`start` returns at once. If the device is not registered yet, registration runs in the background (retried, and retried again when the app returns to the foreground). Events emitted meanwhile wait in memory, up to 1000, with their ids, times and agent context, and go out once it succeeds.

Wrap the agent's own task in `withAgentContext`: the context follows `await`s inside it, but a widget's `onPressed` runs outside it.

## Your backend's two routes

**Provisioning** (`provisionUrl`)
- Request: `POST` with body `{"public_jwk": {"kty": "OKP", "crv": "Ed25519", "x": "…"}, "name": "…"}` and the headers from `headers`.
- Response: `{"source_id": "src_…"}`.
- Registration can be retried with the same key after a lost response, so make it idempotent per public key.

**Forwarding** (`forwardUrl`)
- Request: `POST` with body `{"events": [{"event": {…}, "sig": "…"}]}` and the headers from `headers`.
- Response: HalvorAI's response, status and body unchanged. Events missing from its `results` count as `unconfirmed`.

## What it handles

| | |
| --- | --- |
| Key storage | iOS Keychain, readable after first unlock (so a background flush can sign), this device only: never in iCloud Keychain or a backup restored to another phone. Android Keystore-backed encryption; if a stored key can't be decrypted, a new one is registered. |
| Reinstalls | iOS keeps Keychain items when an app is deleted. A marker in the app's data directory spots a fresh install, and the old key (possibly another user's) is replaced. |
| Offline | Batches that run out of retries are kept on disk (JSON lines, written atomically), at most 5 MB and 7 days, oldest dropped first and reported as `spool` errors. They are re-sent on the next start, flush or return to the foreground. HalvorAI drops duplicates for good, so a re-send is never counted twice. |
| Lifecycle | Going to the background sends the queue (3-second budget); coming back retries registration and spooled batches. Otherwise batches go out every 5 seconds or at 100 events. |
| Account deletion | `resetIdentity()` forgets the key and the spool; the next `start` registers a new key. |

## Debug builds without a backend

```dart
final halvor = await HalvorFlutter.start(
  environment: Environment.test,
  debugApiKey: 'hk_test_…',
);
```

This registers and sends straight to the HalvorAI sandbox. It only works with an `hk_test_` key in a debug build. A release or profile build, or a live key, disables the SDK and reports a `config` error, because anything in an app binary is public.

## Setup

- **Android:** `minSdkVersion 23` or higher (needed by `flutter_secure_storage`).
- **iOS:** nothing extra.

## Not yet

- Retrying the moment the network comes back (today: on the next interval, flush or return to the foreground).
- Hardware-backed keys: the Secure Enclave can't do Ed25519. That needs ES256 in a future APE version.
- An example app, and tests on real devices. The unit tests use in-memory key storage, so `SecureKeyStore` itself has only been exercised through the plugin's own tests.

## License

Apache-2.0
