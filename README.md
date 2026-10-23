# ingest-dart

Dart and Flutter SDKs for HalvorAI: signed, attributed payment events for AI agents.

| Package | Status | What it is |
| --- | --- | --- |
| [`halvorai_ingest`](packages/halvorai_ingest) | Developer preview | Pure-Dart core: event models, signing, validation, redaction, delivery |
| [`halvorai_ingest_flutter`](packages/halvorai_ingest_flutter) | Developer preview | iOS and Android: device keys in secure storage, registration through your backend, disk spool, app-lifecycle flushing |

Siblings: [ingest-js](https://github.com/halvorAI/ingest-js) (Node.js) and [ingest-python](https://github.com/halvorAI/ingest-python).

## Develop

This is a [pub workspace](https://dart.dev/tools/pub/workspaces) with a Flutter package in it, so resolve it with Flutter (which includes Dart). From the root:

```bash
flutter pub get
flutter analyze
(cd packages/halvorai_ingest && dart test)
(cd packages/halvorai_ingest_flutter && flutter test)
```

## Security

Report vulnerabilities privately to hello@halvorai.com.

## License

Apache-2.0
