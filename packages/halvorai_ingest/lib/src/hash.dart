import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'canonical.dart';

/// APE instruction digest: `sha256:` + hex of the UTF-8 instruction text.
String hashInstruction(String text) => 'sha256:${sha256.convert(utf8.encode(text))}';

/// Digest of an evidence value as stored in `evidence[].sha256`: UTF-8 bytes for a string,
/// the RFC 8785 canonical form for anything else.
String evidenceSha256(Object value) {
  final text = value is String ? value : canonicalize(value);
  return 'sha256:${sha256.convert(utf8.encode(text))}';
}
