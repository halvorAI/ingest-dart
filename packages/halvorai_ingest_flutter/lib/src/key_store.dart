import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the device's private signing key lives.
abstract interface class KeyStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// The platform's secure storage: the Keychain on iOS, Keystore-backed encryption on Android.
///
/// On iOS the key is readable after the first unlock (so a background flush can sign) and is
/// `ThisDevice` only: it is never synced to iCloud Keychain or restored onto another phone.
/// On Android, if the stored key cannot be decrypted (for example after a Keystore reset), the
/// plugin clears it and the SDK registers a new key.
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A [KeyStore] in memory, for tests.
class MemoryKeyStore implements KeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
