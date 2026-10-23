import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';

SignedEnvelope _envelope(String id, {int padding = 0}) =>
    SignedEnvelope({'id': id, 'pad': 'x' * padding}, 'sig');

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('halvor_spool_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('keeps batches in order and reads them back', () async {
    final spool = FileSpool(dir);
    await spool.write([_envelope('evt_a1'), _envelope('evt_a2')]);
    await spool.write([_envelope('evt_b1')]);

    final ids = await spool.list();
    expect(ids, hasLength(2));
    expect((await spool.read(ids.first)).map((e) => e.id), ['evt_a1', 'evt_a2']);
    expect((await spool.read(ids.last)).map((e) => e.id), ['evt_b1']);
    expect(dir.listSync().map((f) => f.path), everyElement(isNot(endsWith('.tmp'))));
  });

  test('replace keeps only what is left, and remove deletes', () async {
    final spool = FileSpool(dir);
    await spool.write([_envelope('evt_1'), _envelope('evt_2')]);
    final id = (await spool.list()).single;

    await spool.replace(id, [_envelope('evt_2')]);
    expect((await spool.read(id)).map((e) => e.id), ['evt_2']);

    await spool.replace(id, []);
    expect(await spool.list(), isEmpty);
    await spool.remove(id); // already gone: no error
  });

  test('skips lines it cannot read', () async {
    final spool = FileSpool(dir);
    await spool.write([_envelope('evt_ok')]);
    final id = (await spool.list()).single;
    final file = File('${dir.path}/$id');
    file.writeAsStringSync('not json\n{"event":1}\n${file.readAsStringSync()}');
    expect((await spool.read(id)).map((e) => e.id), ['evt_ok']);
  });

  test('deletes the oldest batches beyond the size limit and says how many events', () async {
    final evicted = <(int, String)>[];
    final spool = FileSpool(dir, maxBytes: 3000, onEvict: (n, why) => evicted.add((n, why)));
    for (var i = 0; i < 3; i++) {
      await spool.write([_envelope('evt_${i}a', padding: 1000), _envelope('evt_${i}b')]);
    }
    final ids = await spool.list();
    expect(ids, hasLength(2));
    expect((await spool.read(ids.first)).first.id, 'evt_1a', reason: 'the oldest went first');
    expect(evicted.single.$1, 2);
    expect(evicted.single.$2, contains('KB'));
  });

  test('deletes batches older than the age limit', () async {
    var now = DateTime.utc(2026, 10, 1);
    final evicted = <int>[];
    final spool = FileSpool(dir, clock: () => now, onEvict: (n, _) => evicted.add(n));
    await spool.write([_envelope('evt_old')]);
    now = now.add(const Duration(days: 8));
    await spool.write([_envelope('evt_new')]);

    final ids = await spool.list();
    expect(ids, hasLength(1));
    expect((await spool.read(ids.single)).single.id, 'evt_new');
    expect(evicted, [1]);
  });
}
