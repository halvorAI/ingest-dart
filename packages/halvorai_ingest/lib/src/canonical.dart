/// JSON Canonicalization Scheme (RFC 8785), byte-identical to the TypeScript SDK's
/// `canonicalize` (`ingest-js/vendor/schema/canonical.ts`).
library;

/// Thrown when a value has no canonical JSON form.
class CanonicalError extends Error {
  CanonicalError(this.message);

  final String message;

  @override
  String toString() => 'CanonicalError: $message';
}

/// Largest integer an IEEE 754 double holds exactly. JCS numbers are doubles, so larger
/// integers would sign differently here than in JavaScript.
const int maxSafeInteger = 9007199254740991;

/// Returns the JCS string for a JSON value: `null`, `bool`, `num`, `String`, `List` or `Map`
/// with `String` keys.
String canonicalize(Object? value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Object? value, StringBuffer out) {
  switch (value) {
    case null:
      out.write('null');
    case final bool b:
      out.write(b ? 'true' : 'false');
    case final String s:
      writeJsonString(s, out);
    case final int i:
      if (i > maxSafeInteger || i < -maxSafeInteger) {
        throw CanonicalError('integer $i is outside the IEEE 754 safe range');
      }
      out.write(i.toString());
    case final double d:
      out.write(_number(d));
    case final List<Object?> list:
      out.write('[');
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',');
        _write(list[i], out);
      }
      out.write(']');
    case final Map<Object?, Object?> map:
      final keys = <String>[];
      for (final key in map.keys) {
        if (key is! String) throw CanonicalError('object keys must be strings');
        keys.add(key);
      }
      // String.compareTo compares UTF-16 code units, the order RFC 8785 requires.
      keys.sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        writeJsonString(keys[i], out);
        out.write(':');
        _write(map[keys[i]], out);
      }
      out.write('}');
    default:
      throw CanonicalError('cannot canonicalize a ${value.runtimeType}');
  }
}

/// ECMAScript Number::toString. Dart prints the same shortest round-trip digits but keeps
/// `.0` on integral values and the sign of negative zero.
String _number(double d) {
  if (!d.isFinite) throw CanonicalError('numbers must be finite');
  if (d == 0) return '0';
  final s = d.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Writes [s] as ECMAScript `JSON.stringify` would, including escaping lone surrogates.
void writeJsonString(String s, StringBuffer out) {
  out.write('"');
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0a:
        out.write(r'\n');
      case 0x0c:
        out.write(r'\f');
      case 0x0d:
        out.write(r'\r');
      default:
        if (c < 0x20) {
          out.write(r'\u');
          out.write(c.toRadixString(16).padLeft(4, '0'));
        } else if (c >= 0xd800 && c <= 0xdbff) {
          final paired = i + 1 < units.length && units[i + 1] >= 0xdc00 && units[i + 1] <= 0xdfff;
          if (paired) {
            out.writeCharCode(c);
            out.writeCharCode(units[++i]);
          } else {
            out.write(r'\u');
            out.write(c.toRadixString(16));
          }
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          out.write(r'\u');
          out.write(c.toRadixString(16));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
}
