/// Where batches wait when delivery runs out of retries, so they survive a restart. The
/// Flutter package stores them as files; the core only defines the contract.
library;

import 'transport.dart';

/// Durable storage for undelivered batches. Implementations should bound their own size and
/// may throw; the client reports failures as `spool` errors.
abstract interface class Spool {
  /// Stores a batch as one entry.
  Future<void> write(List<SignedEnvelope> envelopes);

  /// Entry ids, oldest first.
  Future<List<String>> list();

  /// The envelopes in one entry, skipping any that cannot be read.
  Future<List<SignedEnvelope>> read(String id);

  /// Keeps only [remaining] in the entry, after part of it was delivered.
  Future<void> replace(String id, List<SignedEnvelope> remaining);

  Future<void> remove(String id);
}

/// A [Spool] in memory. It does not survive a restart; for tests and short-lived processes.
class MemorySpool implements Spool {
  final _entries = <String, List<SignedEnvelope>>{};
  var _next = 0;

  int get length => _entries.values.fold(0, (sum, e) => sum + e.length);

  @override
  Future<void> write(List<SignedEnvelope> envelopes) async {
    if (envelopes.isEmpty) return;
    _entries['${_next++}'.padLeft(12, '0')] = [...envelopes];
  }

  @override
  Future<List<String>> list() async => _entries.keys.toList()..sort();

  @override
  Future<List<SignedEnvelope>> read(String id) async => [...?_entries[id]];

  @override
  Future<void> replace(String id, List<SignedEnvelope> remaining) async {
    if (remaining.isEmpty) {
      _entries.remove(id);
    } else if (_entries.containsKey(id)) {
      _entries[id] = [...remaining];
    }
  }

  @override
  Future<void> remove(String id) async => _entries.remove(id);
}
