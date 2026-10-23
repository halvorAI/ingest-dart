# ingest-dart

Dart and Flutter SDKs for HalvorAI: signed, attributed payment events for AI agents.

| Package | Status | What it is |
| --- | --- | --- |
| [`halvorai_ingest`](packages/halvorai_ingest) | Developer preview | Pure-Dart core: event models, signing, validation, redaction, delivery |
| `halvorai_ingest_flutter` | Planned | Secure key storage, disk spool, app-lifecycle flushing, device provisioning |

Siblings: [ingest-js](https://github.com/halvorAI/ingest-js) (Node.js) and [ingest-python](https://github.com/halvorAI/ingest-python).

## Develop

This is a [pub workspace](https://dart.dev/tools/pub/workspaces). From the root:

```bash
dart pub get
dart analyze
(cd packages/halvorai_ingest && dart test)
```

## Security

Report vulnerabilities privately to hello@halvorai.com.

## License

Apache-2.0
