/// Strips card numbers, CVCs, secret keys and private keys from free text, with the same
/// patterns as the TypeScript SDK (`ingest-js/src/redact.ts`).
library;

import 'time.dart';

/// An extra pattern to redact, replaced with `[redacted:<label>]` (or `[redacted]`).
class ExtraPattern {
  const ExtraPattern(this.pattern, {this.label});

  final RegExp pattern;
  final String? label;
}

final _secretKey =
    RegExp(r'\b(?:sk_live_|sk_test_|rk_live_|whsec_|hk_live_|hk_test_)[0-9A-Za-z]+\b');
final _pemPrivate =
    RegExp(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----');
final _jwkD = RegExp(r'"d"\s*:\s*"[^"]*"');
final _cvc = RegExp(r'\b(cvc|cvv2?|security code)("\s*:\s*"|\s*[:=]\s*|\s+)(\d{3,4})(")?',
    caseSensitive: false);
final _panRun = RegExp(r'\d(?:[ -]?\d)*');
final _separators = RegExp(r'[ -]');

const _maxDepth = 64;

/// True for a Luhn-valid run of 13 to 19 digits, spaces or dashes allowed between digits.
/// Whole runs only, so order numbers do not trip it by chance on a substring.
bool containsPan(String text) => _panRun.allMatches(text).any((m) => _isPan(m[0]!));

bool _isPan(String run) {
  final digits = run.replaceAll(_separators, '');
  return digits.length >= 13 && digits.length <= 19 && _luhnValid(digits);
}

bool _luhnValid(String digits) {
  var sum = 0;
  var double = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 48;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return sum % 10 == 0;
}

/// Strip PANs, CVCs, secret keys and private keys from a string.
String redactText(String text, {List<ExtraPattern> extraPatterns = const []}) {
  var out = text
      .replaceAll(_pemPrivate, '[redacted:private-key]')
      .replaceAll(_secretKey, '[redacted:secret-key]')
      .replaceAll(_jwkD, '"d":"[redacted:private-key]"')
      .replaceAllMapped(_panRun, (m) => _isPan(m[0]!) ? '[redacted:pan]' : m[0]!)
      .replaceAllMapped(_cvc, (m) => '${m[1]}${m[2]}[redacted:cvc]${m[4] ?? ''}');
  for (final extra in extraPatterns) {
    final label = extra.label;
    out = out.replaceAll(
      extra.pattern,
      label != null && label.isNotEmpty ? '[redacted:$label]' : '[redacted]',
    );
  }
  return out;
}

/// A copy of [value] with every string redacted. A private JWK (an object with string `kty`
/// and `d`) becomes `[redacted:private-key]`. Never changes the input.
Object? redactDeep(Object? value, {List<ExtraPattern> extraPatterns = const []}) =>
    _walk(value, extraPatterns, Set<Object>.identity(), 0);

Object? _walk(Object? value, List<ExtraPattern> extras, Set<Object> seen, int depth) {
  if (value is String) return redactText(value, extraPatterns: extras);
  if (value is DateTime) return formatUtc(value);
  if (value is! List && value is! Map) return value;
  if (depth >= _maxDepth) return '[depth-limit]';
  if (!seen.add(value!)) return '[circular]';
  try {
    if (value is List) {
      return [for (final item in value) _walk(item, extras, seen, depth + 1)];
    }
    final map = value as Map;
    if (map['kty'] is String && map['d'] is String) return '[redacted:private-key]';
    return {
      for (final entry in map.entries) entry.key: _walk(entry.value, extras, seen, depth + 1),
    };
  } finally {
    // Only cycles are circular; the same object twice in different branches is fine.
    seen.remove(value);
  }
}
