/// HalvorAI for Flutter apps: each install signs its own events with a key kept in secure
/// storage, and your backend forwards them to HalvorAI. The app never holds an API key.
///
/// Re-exports `package:halvorai_ingest`, so one import gives the event models and
/// `withAgentContext` too.
library;

export 'package:halvorai_ingest/halvorai_ingest.dart';

export 'src/device_identity.dart' show DeviceIdentity, pendingKid;
export 'src/file_spool.dart' show FileSpool, SpoolEvictHandler;
export 'src/halvor_flutter.dart' show HalvorFlutter, defaultRegistrationRetryDelays;
export 'src/key_store.dart' show KeyStore, MemoryKeyStore, SecureKeyStore;
export 'src/provisioning.dart' show HeadersCallback, ProvisioningException, registerKey;
