# halvorai_ingest

Signed, attributed payment events for AI agents, in pure Dart. HalvorAI records each payment an agent makes, with the agent, the owner it acted for, the instruction it followed and the network proof that came with it. It is never in the payment path: `emit` returns at once, never throws and never waits on the network.

> **Developer preview.** This is the core package. Flutter apps will use `halvorai_ingest_flutter` (in progress), which adds secure key storage, a disk spool and device provisioning on top of it.

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

Events are batched (100, or every second), retried with backoff on network errors, 408, 429 and 5xx, and split on 413. `stats().accepted` counts only events the API confirmed; an event the response has no result for counts as `unconfirmed`, which with `ForwardingTransport` usually means the backend is not returning HalvorAI's response unchanged. A 400/401/403/422 is not retried; the error carries the API's code (`unknown_source`, `invalid_signature`, …). Pass a `Spool` to keep batches that run out of retries; they are re-sent on the next `flush()` or start, and an entry the API refuses for good is removed rather than blocking the rest.

## Agent context

`withAgentContext` uses `Zone` values, so the context follows `await`, timers and futures started inside it. Callbacks registered outside it, such as Flutter widget handlers, do not see it: wrap the agent's task, or set `agent:`/`owner:` on the event.

## Develop

```bash
dart pub get
dart analyze
dart test
```

`test/fixtures/sign-vector.json` is shared with ingest-python. `test/fixtures/jcs-vectors.json` comes from the TypeScript SDK's `canonicalize` via `tool/gen_jcs_vectors.mjs`.

## License

Apache-2.0
