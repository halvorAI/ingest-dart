import 'dart:convert';
import 'dart:io';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:test/test.dart';

/// The shared cases from ape-schema/conformance, which the Node.js and Python SDKs run too.
/// Refresh with tool/sync_conformance.sh.
final _cases = ((jsonDecode(File('test/fixtures/conformance/events.json').readAsStringSync())
        as Map)['cases'] as List)
    .cast<Map<String, Object?>>();

/// `valid`, or why the event is invalid: `pan` (a card number in a free-text field) or
/// `schema` (anything else).
String _verdict(Map<String, Object?> event) {
  final problems = validateEvent(event);
  if (problems.isEmpty) return 'valid';
  return problems.any((p) => p.contains('pan_detected')) ? 'pan' : 'schema';
}

void main() {
  test('the shared file has cases', () => expect(_cases, isNotEmpty));

  for (final c in _cases) {
    test(c['name'], () {
      final expected = c['expect'] == 'valid' ? 'valid' : c['rule'];
      final event = (c['event'] as Map).cast<String, Object?>();
      expect(_verdict(event), expected, reason: '${c['note'] ?? ''}\n${validateEvent(event)}');
    });
  }
}
