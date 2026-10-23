/// Detached APE JWS (Ed25519 / EdDSA) over the JCS form of an event, matching
/// `@halvorai/schema` sign.ts and `halvorai_ingest/sign.py` byte for byte.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'canonical.dart';

const _headerTyp = 'ape+jws';
const _apeVersion = '0.1';

final _ed25519 = Ed25519();

/// A source's Ed25519 signing key, as a private OKP JWK with a `kid` (the `src_` id).
///
/// Keep the private half secret. [publicJwk] is what gets registered with HalvorAI and what
/// anyone uses to check a signature.
class SourceKey {
  SourceKey._(this.kid, this._seed, this._x);

  /// The key id, which is also `event.source.id` on every event this key signs.
  final String kid;
  final List<int> _seed;
  final List<int> _x;
  Future<SimpleKeyPair>? _keyPair;

  /// Parses a private JWK (`kty: OKP`, `crv: Ed25519`, `d`, `x`, `kid`). Throws
  /// [FormatException] if it is not one; checks that `x` belongs to `d` when signing.
  factory SourceKey.fromJwk(Map<String, Object?> jwk) {
    if (jwk['kty'] != 'OKP' || jwk['crv'] != 'Ed25519') {
      throw const FormatException('source key must be an Ed25519 JWK (kty OKP, crv Ed25519)');
    }
    final d = jwk['d'];
    final x = jwk['x'];
    final kid = jwk['kid'];
    if (d is! String || d.isEmpty) {
      throw const FormatException('source key must be a private JWK (d is missing)');
    }
    if (x is! String || x.isEmpty) throw const FormatException('source key is missing x');
    if (kid is! String || kid.isEmpty) throw const FormatException('source key is missing kid');
    final seed = base64UrlDecodeUnpadded(d);
    final pub = base64UrlDecodeUnpadded(x);
    if (seed.length != 32 || pub.length != 32) {
      throw const FormatException('source key d and x must be 32 bytes');
    }
    return SourceKey._(kid, seed, pub);
  }

  /// Parses a private JWK given as a JSON string or a map. Throws [FormatException].
  factory SourceKey.parse(Object raw) {
    final Object? decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw const FormatException('source key must be a JSON object');
    return SourceKey.fromJwk(decoded.cast<String, Object?>());
  }

  /// Creates a new random key. [kid] should be the `src_` id HalvorAI returns when the public
  /// half is registered; use [withKid] once it is known.
  static Future<SourceKey> generate({String kid = 'src_local'}) async {
    final pair = await _ed25519.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final pub = await pair.extractPublicKey();
    return SourceKey._(kid, seed, pub.bytes);
  }

  /// The same key under another id, for when registration assigns the `src_` id.
  SourceKey withKid(String kid) => SourceKey._(kid, _seed, _x);

  /// The public half as a JWK, safe to share and register.
  Map<String, String> get publicJwk =>
      {'kty': 'OKP', 'crv': 'Ed25519', 'x': base64UrlEncodeUnpadded(_x), 'kid': kid};

  /// The private JWK. Store it only in secure storage.
  Map<String, String> toJwk() => {...publicJwk, 'd': base64UrlEncodeUnpadded(_seed)};

  Future<SimpleKeyPair> _pair() => _keyPair ??= () async {
        final pair = await _ed25519.newKeyPairFromSeed(_seed);
        final derived = (await pair.extractPublicKey()).bytes;
        if (!_bytesEqual(derived, _x)) {
          throw const FormatException('source key x does not match d');
        }
        return pair;
      }();

  @override
  String toString() => 'SourceKey(kid: $kid)';
}

/// Signs the JCS form of [event] and returns a detached compact JWS (`header..signature`).
/// The header `kid` is `event.source.id`.
Future<String> signEvent(Map<String, Object?> event, SourceKey key) async {
  final header = _header(_sourceId(event));
  final signingInput = '$header.${_payload(event)}';
  final signature = await _ed25519.sign(utf8.encode(signingInput), keyPair: await key._pair());
  return '$header..${base64UrlEncodeUnpadded(signature.bytes)}';
}

/// True only for a valid detached APE JWS over exactly this [event]. Never throws.
///
/// [publicJwk] needs `x`; a private JWK works too.
Future<bool> verifyEvent(
    Map<String, Object?> event, String sig, Map<String, Object?> publicJwk) async {
  try {
    final parts = sig.split('.');
    if (parts.length != 3 || parts[0].isEmpty || parts[1].isNotEmpty || parts[2].isEmpty) {
      return false;
    }
    final header = jsonDecode(utf8.decode(base64UrlDecodeUnpadded(parts[0])));
    if (header is! Map ||
        header['alg'] != 'EdDSA' ||
        header['typ'] != _headerTyp ||
        header['ape'] != _apeVersion ||
        header['kid'] != _sourceId(event)) {
      return false;
    }
    final x = publicJwk['x'];
    if (x is! String) return false;
    final signingInput = '${parts[0]}.${_payload(event)}';
    return await _ed25519.verify(
      utf8.encode(signingInput),
      signature: Signature(
        base64UrlDecodeUnpadded(parts[2]),
        publicKey: SimplePublicKey(base64UrlDecodeUnpadded(x), type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

String _sourceId(Map<String, Object?> event) {
  final source = event['source'];
  final id = source is Map ? source['id'] : null;
  if (id is! String || id.isEmpty) {
    throw ArgumentError('event.source.id is required to sign an event');
  }
  return id;
}

/// Compact JSON with the key order sign.ts uses: alg, kid, typ, ape.
String _header(String kid) {
  final json = StringBuffer('{"alg":"EdDSA","kid":');
  writeJsonString(kid, json);
  json.write(',"typ":"$_headerTyp","ape":"$_apeVersion"}');
  return base64UrlEncodeUnpadded(utf8.encode(json.toString()));
}

String _payload(Map<String, Object?> event) =>
    base64UrlEncodeUnpadded(utf8.encode(canonicalize(event)));

String base64UrlEncodeUnpadded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> base64UrlDecodeUnpadded(String text) =>
    base64Url.decode(text.padRight(text.length + (4 - text.length % 4) % 4, '='));

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
