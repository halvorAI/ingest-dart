# halvorai_ingest

Signed, attributed payment events for AI agents, in pure Dart. HalvorAI records each payment an agent makes, with the agent, the owner it acted for, the instruction it followed and the network proof that came with it. It is never in the payment path: `emit` returns at once, never throws and never waits on the network.

> **Developer preview.** This is the core package. Flutter apps use [`halvorai_ingest_flutter`](../halvorai_ingest_flutter), which adds secure key storage, a disk spool and device provisioning on top of it.

- Docs: [docs.halvorai.com](https://docs.halvorai.com)
- Event format: [Agent Payment Event (APE) v0.1](https://schema.halvorai.com)
- Dart 3.6 or later; no Flutter or `dart:io` imports

## Try it offline

No account needed. Events are signed with your own Ed25519 key and handed to your `sink`:

```dart
final halvor = HalvorClient(
  sourceKey: await SourceKey.generate(),
  environment: Environment.test,
  sink: (envelopes) => print(jsonEncode(envelopes)),
);

await withAgentContext(
  const AgentContext(
    agent: AgentRef(id: 'agt_travel_12', name: 'Travel booking agent'),
    owner: OwnerRef(id: 'own_u_4410', type: OwnerType.person, country: 'US'),
    instruction: InstructionRef(id: 'task_8890', text: r'Book a return flight to Austin under $500'),
  ),
  () async {
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

await halvor.close();
```

Instruction text is hashed on the device and never sent. Anyone with the public half of the key can check an envelope with `verifyEvent(envelope.event, envelope.sig, sourceKey.publicJwk)`. Signatures are byte-identical to the Node.js and Python SDKs.

`emitJson(Map)` takes the same partial-event JSON the other SDKs take; adapters use it.

## Destinations

Give the client exactly one:

| Option | Use |
| --- | --- |
| `sink:` | Offline: you get the signed envelopes. |
| `transport: ForwardingTransport(url, headers: …)` | **Apps.** Your backend checks the caller and forwards the body unchanged to HalvorAI. The app never holds an API key. |
| `apiKey: 'hk_test_…'` | Servers, and debug builds. Test keys go to the sandbox, live keys to production; `endpoint:` overrides. |

A bad configuration does not throw. It disables the client, reports a `config` error once through `onError`, and counts dropped events in `stats()`.

## Delivery

Delivery follows HalvorAI's shared SDK behaviour ([docs/SDK.md](https://github.com/halvorAI/ape-schema/blob/main/docs/SDK.md)), as the Node.js and Python SDKs do:

- Events are batched (100, or every second). Network errors, 408, 425, 429 and 5xx are retried with backoff, and a 413 splits the batch.
- **400, 401, 403, 404, 405, 409, 410, 415 and 422 are permanent.** The batch is counted as dropped once, and the error carries the API's code (`unknown_source`, `invalid_signature`, …) and request id.
- **Each event is counted by its result.** An event the response has no result for counts as accepted; the client warns once with a `config` error, since HalvorAI always answers every event, so a missing result usually means a forwarding backend isn't passing the response through.
- **Pass a `Spool`** to keep batches that run out of retries. They're re-sent on the next `flush()` or start. A batch the API refuses for good goes to the spool's dead letters and is never replayed.

**Exception:** with `ForwardingTransport`, a 401 or 403 from your backend is retried and spooled, because on a phone it usually means an expired session.

Dart has no reliable exit hook, so call `close()` before a server process exits. Flutter apps get this from `halvorai_ingest_flutter`, which flushes when the app goes to the background.

## x402

`package:halvorai_ingest/x402.dart` records x402 v2 payments made over `package:http`. It only reads payment headers; requests and responses pass through unchanged. Give `HalvorX402Client` to your x402 client **as the HTTP client it pays with**, so it sees every request that client makes:

```dart
import 'package:halvorai_ingest/x402.dart';

final http = HalvorX402Client(halvor); // halvor: a HalvorClient, or HalvorFlutter in an app
// e.g. YourX402Client(httpClient: http, signer: …)
```

Wrapped around the outside of the x402 client instead, it would only see the final response, not the 402 or the signed retry.

What it records:
- **The 402 challenge** (`PAYMENT-REQUIRED`) becomes `payment.requested`.
- **The signed retry** (`PAYMENT-SIGNATURE`) becomes `payment.authorized`, linked to its challenge with `related.previous_event_id`, with the payload attached as evidence. x402 gives a challenge no id, so the match uses the URL, the terms and the `withAgentContext` the request ran in. If that leaves more than one open challenge, the payment is recorded with no link rather than a guessed one, so run concurrent purchases in their own `withAgentContext`.
- **The settlement** (`PAYMENT-RESPONSE`) becomes `payment.settled` or `payment.failed`, with the same `payment_id`.
- **A header it can't decode,** or a challenge without a network or token address, is reported as `invalid_event`, never guessed and never thrown into the request.

The events are the same as the Node.js and Python SDKs produce, checked against their shared fixtures.

## Agent context

`withAgentContext` uses `Zone` values, so the context follows `await`, timers and futures started inside it. Callbacks registered outside it, such as Flutter widget handlers, do not see it: wrap the agent's task, or set `agent:`/`owner:` on the event.

## Develop

```bash
dart pub get
dart analyze
dart test
```

`test/fixtures/conformance/` is a copy of [ape-schema's conformance files](https://schema.halvorai.com/conformance/), the events, signing vector and canonical-JSON vectors the Node.js and Python SDKs test against too. Refresh it with `tool/sync_conformance.sh`. `test/fixtures/x402/` holds the Node.js SDK's x402 fixtures and its output for them, from `tool/gen_x402_expected.mjs`.

## License

Apache-2.0
