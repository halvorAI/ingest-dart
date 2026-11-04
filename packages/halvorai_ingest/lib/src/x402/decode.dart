import 'dart:convert';

/// Decodes an x402 v2 header value: base64 (standard or URL-safe, padding optional) of a JSON
/// object. Throws [FormatException] on bad input.
Map<String, Object?> decodePaymentHeader(String header) {
  final trimmed = header.trim();
  if (trimmed.isEmpty) throw const FormatException('empty payment header');
  final b64 = trimmed.replaceAll('-', '+').replaceAll('_', '/');
  final padded = b64.padRight(b64.length + (4 - b64.length % 4) % 4, '=');
  final String json;
  try {
    json = utf8.decode(base64.decode(padded));
  } on FormatException {
    throw const FormatException('payment header is not valid base64');
  }
  final Object? value;
  try {
    value = jsonDecode(json);
  } on FormatException {
    throw const FormatException('payment header is not valid JSON');
  }
  if (value is! Map) throw const FormatException('payment header is not a JSON object');
  return value.cast<String, Object?>();
}

/// Encodes a value as an x402 header (standard base64 of its JSON), for fixtures and tests.
String encodePaymentHeader(Object? value) => base64.encode(utf8.encode(jsonEncode(value)));
