import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:halvorai_ingest/halvorai_ingest.dart';

/// Called when the spool deletes batches to stay within its limits.
typedef SpoolEvictHandler = void Function(int envelopes, String reason);

/// A [Spool] on disk: one JSON-lines file per batch, oldest first.
///
/// Writes go to a temporary file that is then renamed, so a crash never leaves half a batch.
/// The spool keeps at most [maxBytes] and nothing older than [maxAge]; the oldest batches go
/// first, and [onEvict] is told how many events were lost. HalvorAI catches duplicates
/// permanently, so a batch re-sent after a crash is never counted twice.
class FileSpool implements Spool {
  FileSpool(
    this.directory, {
    this.maxBytes = 5 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
    this.onEvict,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Directory directory;
  final int maxBytes;
  final Duration maxAge;
  SpoolEvictHandler? onEvict;
  final DateTime Function() _now;
  final _random = Random();

  static final _entryName = RegExp(r'^(\d{17})-[0-9a-f]{8}\.jsonl$');

  @override
  Future<void> write(List<SignedEnvelope> envelopes) async {
    if (envelopes.isEmpty) return;
    await directory.create(recursive: true);
    final stamp = _now().microsecondsSinceEpoch.toString().padLeft(17, '0');
    final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    await _writeAtomically('$stamp-$suffix.jsonl', envelopes);
    await _enforceLimits();
  }

  @override
  Future<List<String>> list() async {
    await _enforceLimits();
    return _entries();
  }

  @override
  Future<List<SignedEnvelope>> read(String id) async {
    final file = _file(id);
    if (!await file.exists()) return const [];
    return _parse(await file.readAsString());
  }

  @override
  Future<void> replace(String id, List<SignedEnvelope> remaining) async {
    if (remaining.isEmpty) return remove(id);
    if (!await _file(id).exists()) return;
    await _writeAtomically(id, remaining);
  }

  @override
  Future<void> remove(String id) async {
    try {
      await _file(id).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }

  /// Batches currently on disk, oldest first.
  Future<List<String>> _entries() async {
    if (!await directory.exists()) return const [];
    final names = <String>[
      await for (final entity in directory.list())
        if (entity is File && _entryName.hasMatch(_name(entity))) _name(entity),
    ];
    return names..sort();
  }

  Future<void> _enforceLimits() async {
    await _removeStaleTempFiles();
    final entries = await _entries();
    final cutoff = _now().subtract(maxAge).microsecondsSinceEpoch;
    var expired = 0;
    final kept = <(String, int)>[];
    for (final id in entries) {
      final written = int.parse(_entryName.firstMatch(id)![1]!);
      if (written < cutoff) {
        expired += await _evict(id);
      } else {
        kept.add((id, await _file(id).length()));
      }
    }
    var total = kept.fold(0, (sum, e) => sum + e.$2);
    var overflow = 0;
    for (final (id, size) in kept) {
      if (total <= maxBytes) break;
      overflow += await _evict(id);
      total -= size;
    }
    if (expired > 0) onEvict?.call(expired, 'older than ${maxAge.inDays} days');
    if (overflow > 0) onEvict?.call(overflow, 'spool over ${maxBytes ~/ 1024} KB');
  }

  /// A temp file older than a minute was left by a crash between write and rename; the batch
  /// in it never made it into the spool. A fresh one may belong to a write still under way.
  Future<void> _removeStaleTempFiles() async {
    if (!await directory.exists()) return;
    final cutoff = _now().subtract(const Duration(minutes: 1));
    await for (final entity in directory.list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File || !name.startsWith('.') || !name.endsWith('.tmp')) continue;
      try {
        if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
      } on FileSystemException {
        // Renamed or deleted meanwhile.
      }
    }
  }

  /// Deletes an entry and returns how many events it held.
  Future<int> _evict(String id) async {
    final count = (await read(id)).length;
    await remove(id);
    return count;
  }

  Future<void> _writeAtomically(String id, List<SignedEnvelope> envelopes) async {
    final tmp = File('${directory.path}/.$id.tmp');
    await tmp.writeAsString(
      '${envelopes.map((e) => jsonEncode(e.toJson())).join('\n')}\n',
      flush: true,
    );
    await tmp.rename(_file(id).path);
  }

  static List<SignedEnvelope> _parse(String text) => [
        for (final line in const LineSplitter().convert(text))
          if (line.trim().isNotEmpty)
            if (_tryParse(line) case final SignedEnvelope envelope) envelope,
      ];

  static SignedEnvelope? _tryParse(String line) {
    try {
      final json = jsonDecode(line);
      return json is Map ? SignedEnvelope.fromJson(json.cast<String, Object?>()) : null;
    } on FormatException {
      return null;
    }
  }

  File _file(String id) => File('${directory.path}/$id');

  static String _name(File file) => file.uri.pathSegments.last;
}
