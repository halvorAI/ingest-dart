import 'dart:async';
import 'dart:convert';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:http/http.dart' as http;

/// Headers for requests to your backend, such as the signed-in user's session token. Called
/// before every request, so it can return a fresh token.
typedef HeadersCallback = FutureOr<Map<String, String>> Function();

/// Registering this install's public key failed. The SDK retries; this is reported through
/// `onError` each time.
class ProvisioningException implements Exception {
  const ProvisioningException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'ProvisioningException: $message';
}

/// Registers [key]'s public half and returns the `src_` id.
///
/// With [apiKey] null this calls your backend, per the provisioning contract: `POST url` with
/// `{"public_jwk": {...}, "name": "..."}`, answered with `{"source_id": "src_..."}`. Your
/// backend calls HalvorAI's `POST /v1/sources` with its own key (the server SDKs'
/// `registerDeviceSource` does this).
///
/// With [apiKey] set (debug builds only) this calls HalvorAI's `POST /v1/sources` itself, which
/// answers `201 {"id": "src_..."}`.
Future<String> registerKey({
  required http.Client client,
  required Uri url,
  required SourceKey key,
  required String name,
  HeadersCallback? headers,
  String? apiKey,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final publicJwk = key.publicJwk..remove('kid');
  final direct = apiKey != null;
  final http.Response response;
  try {
    response = await client
        .post(
          url,
          headers: {
            if (!direct) ...await headers?.call() ?? const {},
            if (direct) 'authorization': 'Bearer $apiKey',
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: jsonEncode(
            direct
                ? {'name': name, 'adapter': 'custom', 'public_jwk': publicJwk}
                : {'public_jwk': publicJwk, 'name': name},
          ),
        )
        .timeout(timeout);
  } on TimeoutException {
    throw const ProvisioningException('registration timed out');
  } catch (e) {
    throw ProvisioningException('registration request failed: $e');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw ProvisioningException('registration failed with HTTP ${response.statusCode}',
        status: response.statusCode);
  }
  final Object? id;
  try {
    final body = jsonDecode(response.body);
    id = body is Map ? body[direct ? 'id' : 'source_id'] : null;
  } on FormatException {
    throw ProvisioningException('registration response is not JSON', status: response.statusCode);
  }
  if (id is! String || !id.startsWith('src_')) {
    throw ProvisioningException(
      'registration response has no ${direct ? 'id' : 'source_id'} starting with src_',
      status: response.statusCode,
    );
  }
  return id;
}
