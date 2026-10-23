import 'dart:convert';
import 'dart:io';

import 'package:halvorai_ingest/halvorai_ingest.dart';

import 'key_store.dart';

/// The `kid` a key carries until HalvorAI assigns its `src_` id.
const pendingKid = 'src_pending';

/// This install's signing key: made once, registered once, then reused.
///
/// The key is kept in a [KeyStore]. A marker file in the app's data directory tells a fresh
/// install apart from a restart: iOS keeps Keychain items after an app is deleted, but the data
/// directory goes with it, so a key found without the marker belongs to a previous install
/// (possibly another user's) and is replaced.
class DeviceIdentity {
  DeviceIdentity._(this._store, this._storageKey);

  final KeyStore _store;
  final String _storageKey;

  /// Opens the identity for [environment], clearing a key left by a previous install.
  static Future<DeviceIdentity> open({
    required KeyStore store,
    required Directory dataDirectory,
    required Environment environment,
  }) async {
    final identity = DeviceIdentity._(store, 'halvorai.source_key.${environment.wire}');
    final marker = File('${dataDirectory.path}/install-${environment.wire}');
    if (!await marker.exists()) {
      await store.delete(identity._storageKey);
      await dataDirectory.create(recursive: true);
      await marker.writeAsString(newEventId().replaceFirst('evt_', 'ins_'), flush: true);
    }
    return identity;
  }

  /// The registered key, or null if this install has not been registered yet.
  Future<SourceKey?> registered() async {
    final stored = await _load();
    return stored != null && stored.kid != pendingKid ? stored : null;
  }

  /// The key waiting to be registered, made and stored now if there is none. The same key is
  /// reused across retries and restarts, so a registration that reached the backend but whose
  /// answer was lost does not leave a second key behind.
  Future<SourceKey> pending() async {
    final stored = await _load();
    if (stored != null) return stored;
    final key = await SourceKey.generate(kid: pendingKid);
    await _save(key);
    return key;
  }

  /// Stores the key under the `src_` id the backend returned.
  Future<SourceKey> markRegistered(String sourceId) async {
    final key = (await pending()).withKid(sourceId);
    await _save(key);
    return key;
  }

  /// Forgets the key, for example when the user deletes their account. The next start
  /// registers a new one.
  Future<void> reset() => _store.delete(_storageKey);

  Future<SourceKey?> _load() async {
    final raw = await _store.read(_storageKey);
    if (raw == null) return null;
    try {
      return SourceKey.parse(raw);
    } on FormatException {
      // Unreadable: start over with a new key rather than fail forever.
      await reset();
      return null;
    }
  }

  Future<void> _save(SourceKey key) => _store.write(_storageKey, jsonEncode(key.toJwk()));
}
