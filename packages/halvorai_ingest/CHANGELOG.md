# Changelog

## 0.1.0-dev.1 (unreleased)

- `HalvorClient`: batched, signed (EdDSA) delivery with retries, 413 splitting and an optional `Spool`; `emit` never throws.
- Destinations: offline `sink`, `ForwardingTransport` (your backend forwards to HalvorAI) and `HalvorApiTransport` (`hk_` key).
- `withAgentContext` on `Zone` values; instruction text is hashed locally.
- Typed APE v0.1 models (`EventInput`, `Payment`, `Payee`, `Amount`, `Evidence`, …) and `emitJson` for partial-event JSON.
- `validateEvent`: the APE v0.1 rules of the Node.js SDK, including the card-number guard.
- `SourceKey`, `signEvent`, `verifyEvent`: detached JWS over RFC 8785 JCS, byte-identical to the Node.js and Python SDKs.
- Redaction of card numbers, CVCs, secret keys and private keys, including JSON evidence.

Differences from the Node.js and Python SDKs, on purpose:
- A spool entry the API refuses for good is removed instead of blocking later entries, and a single event that is too large is dropped, never spooled.
- Fatal API errors carry the server's error code.
- A sync error thrown inside `withAgentContext` reaches the caller as a throw.
- A steady trickle of events still goes out every flush interval; the timer is not reset by each `emit`.
- `source.id` and `source.sdk` always come from the client; an input can only set `source.adapter`.

Proposed for all three SDKs (PY-17 to PY-19 and JS-16 to JS-18 in the fix lists); Dart does them already:
- Label keys, `payee.website` and `payee.resource_url` are redacted and checked for card numbers too. Identifiers and rail refs are not, since numeric network ids often pass the Luhn check.
- An event whose `environment` differs from the client's is dropped as `invalid_event`, not sent. `EventInput` has no `environment` field.
- An event the response has no result for counts as `unconfirmed`, not `accepted`, and is not retried; a `config` error is reported once. An empty 2xx body is unconfirmed; a non-JSON 2xx body is still retried.
