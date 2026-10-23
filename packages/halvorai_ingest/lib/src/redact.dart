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
// A CVC is 3 or 4 digits; a longer number after the label is not one, and redacting only its
// first four digits would leave the rest showing.
final _cvc = RegExp(r'\b(cvc|cvv2?|security code)("\s*:\s*"|\s*[:=]\s*|\s+)(\d{3,4})(?!\d)(")?',
    caseSensitive: false);
final _panRun = RegExp(r'\d(?:[ -]?\d)*');
final _separators = RegExp(r'[ -]');

const _maxDepth = 64;

/// True for a Luhn-valid run of 13 to 19 digits, spaces or dashes allowed between digits.
///
/// This is the receiver rule from the APE spec (docs/FIELDS.md), which the server and the other
/// SDKs apply, so validation uses it unchanged. Redaction is broader: see [redactText].
bool containsPan(String text) => _panRun.allMatches(text).any((m) => _isPan(m[0]!));

/// True when some whole digit groups of [run] form a card number on their own. Card numbers are
/// written as one block or in groups of 4 to 6 digits, so a card number with another number next
/// to it (`4111 1111 1111 1111 2026`, `4111111111111111-5`, `ref 9 4111111111111111`) is a run of
/// groups whose leading or trailing groups make up the card.
///
/// Only whole groups of at least 4 digits are tried, never arbitrary stretches: a long number
/// written as one block (1 ETH is `1000000000000000000` wei) is left alone. A card number glued
/// to more digits with no separator can't be told apart from such a number, so it isn't caught.
bool _hasGroupedPan(String run) {
  final groups = run.split(_separators);
  for (var first = 0; first < groups.length; first++) {
    var digits = '';
    for (var last = first; last < groups.length; last++) {
      if (groups[last].length < 4) break;
      digits += groups[last];
      if (digits.length > 19) break;
      final wholeRun = first == 0 && last == groups.length - 1;
      if (!wholeRun && digits.length >= 13 && _cardLike(digits)) return true;
    }
  }
  return false;
}

/// Luhn-valid, not starting with 0 and not one digit repeated: no card number looks like
/// `0000000000000000`, and a block of zeros passes the Luhn check.
bool _cardLike(String digits) =>
    digits.codeUnitAt(0) != 0x30 && digits.split('').toSet().length > 1 && _luhnValid(digits);

/// The spec's rule: the whole run is 13 to 19 digits and passes the Luhn check.
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
///
/// A run of digits (spaces or dashes allowed between them) is redacted whole when it is a card
/// number by the spec's rule, or when some of its digit groups are (see [_hasGroupedPan]).
String redactText(String text, {List<ExtraPattern> extraPatterns = const []}) {
  var out = text
      .replaceAll(_pemPrivate, '[redacted:private-key]')
      .replaceAll(_secretKey, '[redacted:secret-key]')
      .replaceAll(_jwkD, '"d":"[redacted:private-key]"')
      .replaceAllMapped(
          _panRun, (m) => _isPan(m[0]!) || _hasGroupedPan(m[0]!) ? '[redacted:pan]' : m[0]!)
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
