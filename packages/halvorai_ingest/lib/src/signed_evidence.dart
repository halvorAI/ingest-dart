/// Evidence that carries a signature over its own fields. Redacting it would break the signature,
/// so it goes out unchanged or not at all, and only when it is the payload it claims to be.
library;

import 'redact.dart';

/// The fields of an x402 v2 `PaymentPayload`.
const _payloadFields = {'x402Version', 'resource', 'accepted', 'payload', 'extensions'};

/// Whole-number amounts in the token's smallest unit. A long one can pass the card-number check,
/// so these must be digits only and are not scanned. Everything else is.
const _amountPaths = {'accepted.amount', 'payload.authorization.value'};

final _digits = RegExp(r'^\d+$');

const _maxDepth = 64;

/// Why [value] can't be sent as a signed x402 payment payload, or null when it can.
///
/// The answer names a field path, never a value, so it is safe to report.
String? x402PayloadProblem(Object? value, {List<ExtraPattern> extraPatterns = const []}) {
  if (value is! Map ||
      value['x402Version'] is! int ||
      value['accepted'] is! Map ||
      value['payload'] is! Map) {
    return 'not an x402 payment payload';
  }
  if (!value.keys.every(_payloadFields.contains)) return 'unknown top-level field';
  return _scan(value, '', extraPatterns, 0);
}

String? _scan(Object? value, String path, List<ExtraPattern> extras, int depth) {
  String where() => path.isEmpty ? 'the payload' : path;
  bool clean(String s) => redactText(s, extraPatterns: extras) == s;

  if (depth >= _maxDepth) return 'too deep at ${where()}';
  switch (value) {
    case null || bool():
      return null;
    case num():
      return containsPan('$value') ? 'sensitive data at ${where()}' : null;
    case String():
      if (_amountPaths.contains(path)) {
        return _digits.hasMatch(value) ? null : 'amount at $path is not a whole number';
      }
      return clean(value) ? null : 'sensitive data at ${where()}';
    case List():
      for (final (i, item) in value.indexed) {
        final problem = _scan(item, '$path[$i]', extras, depth + 1);
        if (problem != null) return problem;
      }
      return null;
    case Map():
      if (value['kty'] is String && value['d'] is String) return 'private key at ${where()}';
      for (final MapEntry(:key, value: item) in value.entries) {
        if (key is! String || !clean(key)) return 'sensitive field name in ${where()}';
        final problem = _scan(item, path.isEmpty ? key : '$path.$key', extras, depth + 1);
        if (problem != null) return problem;
      }
      return null;
    default:
      return 'unsupported value at ${where()}';
  }
}
