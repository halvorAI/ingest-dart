# Changelog

## 0.1.0-dev.2

- `package:halvorai_ingest/x402.dart`: `HalvorX402Client` records x402 v2 payments over `package:http` as `payment.requested`, `payment.authorized` (linked to its challenge) and `payment.settled`/`payment.failed`. The mappers (`mapPaymentRequired`, `mapPaymentPayload`, `mapSettlementResponse`) give the same events as the Node.js SDK for the shared fixtures.
- `HalvorEmitter`: what adapters take, implemented by `HalvorClient` and by `HalvorFlutter`.
- `flush(spoolOnFailure: true)`, for a process that may be stopped soon: everything in memory reaches the spool without waiting on the network. A batch is written before it is sent and removed once delivered, one that fails stays with no more retries, and a send already under way is given up on so a hung request can't hold up the rest. Only the first batch of a long queue is sent then; the rest wait on disk.
- `Spool.write` returns the new entry's id.
- `HalvorClient`: batched, signed (EdDSA) delivery with retries, 413 splitting and an optional `Spool`; `emit` never throws.
- Destinations: offline `sink`, `ForwardingTransport` (your backend forwards to HalvorAI) and `HalvorApiTransport` (`hk_` key).
- `withAgentContext` on `Zone` values; instruction text is hashed locally.
- Typed APE v0.1 models (`EventInput`, `Payment`, `Payee`, `Amount`, `Evidence`, …) and `emitJson` for partial-event JSON.
- `validateEvent`: the APE v0.1 rules of the Node.js SDK, including the card-number guard.
- `SourceKey`, `signEvent`, `verifyEvent`: detached JWS over RFC 8785 JCS, byte-identical to the Node.js and Python SDKs.
- Redaction of card numbers, CVCs, secret keys and private keys, including JSON evidence.
- `newEventId` and `formatUtc` are public, for layers that stamp events before handing them over.
- Tests run against ape-schema's shared conformance files (`tool/sync_conformance.sh`).
- Redaction catches a card number with more digits next to it: a run is also redacted when some of its whole digit groups (4 or more digits each, split by spaces or dashes) form a card number. Long numbers written as one block, such as wei amounts, are left alone. Validation keeps the spec's whole-run rule.
- A 3 or 4 digit CVC only: `cvc 12345` is no longer half redacted. Label keys that redact to the same text are numbered instead of overwritten.
- `ForwardingTransport` retries and spools 401 and 403 instead of dropping the batch; the direct API transport still treats them as fatal.
- Credential-carrying URLs must be https (`insecureUrlProblem`); http is allowed for loopback only.
- The delivery loop never throws: a custom transport that throws is retried, and unexpected errors are reported.
- A successful delivery replays the spool at once, not on the next emit.
- `HalvorClient.discard()` stops delivery at once, cutting short a retry wait, without spooling. `flush()` after `discard()` returns at once, even if an event was being signed.
- A malformed `endpoint` disables the client instead of throwing. Insecure-URL errors leave out userinfo and query.
- After a replay finds the spool empty, successful batches no longer list the spool each time.

Follows HalvorAI's shared SDK behaviour (ape-schema `docs/SDK.md`), like the Node.js and Python SDKs:
- An event may set its own `environment`; HalvorAI rejects a mismatch per event.
- An event a 2xx response has no result for counts as accepted, with a one-time `config` warning. An empty 2xx body is not retried; a non-JSON one is.
- `occurred_at` is stamped when `emit` is called, not when the batch is built.
- Null optional fields are left out, and a null `instruction` falls back to the agent context.
- Digit runs glued to letters (hex, base64, ids) are not card numbers. (As Node.js 0.3.3 and Python 0.4.1; `docs/SDK.md` §3 doesn't say so yet.)
- 404, 405, 409, 410 and 415 are permanent like 400, 401, 403 and 422, and 425 is retried. Permanent batches go to the spool's dead letters (`Spool.writeDead`), never replayed.
- Errors carry the API's request id, from the body or the `request-id` header.

Different from `docs/SDK.md`, on purpose:
- **x402 payments link to their challenge more carefully.** Node.js and Python remember one challenge per URL, so overlapping requests can link to the wrong one. `HalvorX402Client` matches on URL, terms and agent task, and leaves the link out if that doesn't settle it.
- **`x402.payment_payload` evidence is checked, not skipped.** Redacting it would break its signature, so Node.js 0.3.3 and Python 0.4.1 leave it alone. Here it must have the x402 shape and hold nothing redaction would change (the two amount fields must be digits and are not scanned). If not, that evidence is dropped and reported as `invalid_event`, and the event still goes out. Valid payloads give the same events as the other SDKs.
- **Card-number redaction is stricter.** Besides whole runs, whole digit groups that form a card number are redacted, so `card 4111 1111 1111 1111 2026` doesn't go out. This only changes what is stripped before signing; validation keeps the spec rule, so every event is still one the server and the other SDKs accept.
- `ForwardingTransport` retries and spools 401 and 403, because from a customer backend they mean "session expired, try later". The direct API transport treats them as permanent, as the spec says.
- No exit hook (Dart has no reliable one); call `close()`. No `HALVOR_*` environment variables, since the core also runs in Flutter apps and on the web.
- A sync error thrown inside `withAgentContext` reaches the caller as a throw, and a steady trickle of events still goes out every flush interval.
