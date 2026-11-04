// Runs on a real simulator, emulator or phone, with the real secure storage, app data directory
// and lifecycle, against the demo backend (example/backend, `npm start`).
//
//   flutter test integration_test -d <device>
//
// The tests share one app install and run in order.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halvorai_example/main.dart' show agentContext, backend, userId;
import 'package:halvorai_ingest/x402.dart';
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Future<Map<String, Object?>> admin(String path, [Map<String, Object?>? post]) async {
  final url = Uri.parse('$backend/admin/$path');
  final res = post == null ? await http.get(url) : await http.post(url, body: jsonEncode(post));
  return jsonDecode(res.body) as Map<String, Object?>;
}

Future<List<Map<String, Object?>>> backendEvents() async =>
    ((await admin('events'))['events']! as List).cast<Map<String, Object?>>();

Future<List<String>> backendSources() async =>
    ((await admin('events'))['sources']! as List).cast<String>();

final errors = <SdkError>[];

Future<HalvorFlutter> start({List<Duration> retryDelays = defaultRetryDelays}) =>
    HalvorFlutter.start(
      environment: Environment.test,
      provisionUrl: Uri.parse('$backend/halvor/sources'),
      forwardUrl: Uri.parse('$backend/halvor/events'),
      headers: () => {'authorization': 'Bearer $userId'},
      deviceName: 'integration test (${Platform.operatingSystem})',
      onError: errors.add,
      flushInterval: const Duration(hours: 1),
      retryDelays: retryDelays,
    );

Future<void> ready(HalvorFlutter halvor) async {
  for (var i = 0; i < 100 && !halvor.isReady; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(halvor.isReady, isTrue, reason: 'registration did not finish: $errors');
}

String pay(HalvorFlutter halvor, String id) => withAgentContext(
      agentContext,
      () => halvor.emit(EventInput.settled(
        payment: Payment(
          paymentId: id,
          amount: const Amount.minor('1299', 'USD'),
          ref: StripeRef(paymentIntent: id),
        ),
        payee: const Payee.merchant(name: 'Example Data Co'),
      )),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Start clean: forget any key a previous run left, and empty the backend.
    final old = await start();
    await old.resetIdentity();
    await admin('reset', {});
    errors.clear();
  });

  testWidgets('registers a key kept in secure storage and delivers signed events', (_) async {
    final halvor = await start();
    await ready(halvor);
    expect(halvor.sourceId, startsWith('src_demo_'));

    pay(halvor, 'pi_it_1');
    pay(halvor, 'pi_it_2');
    expect(await halvor.flush(timeout: const Duration(seconds: 10)), isTrue);

    final events = await backendEvents();
    expect(events, hasLength(2));
    expect(events.every((e) => e['verified'] == true), isTrue,
        reason: 'signatures checked upstream');
    expect(events.map((e) => e['source']).toSet(), {halvor.sourceId});
    expect(errors, isEmpty);
    await halvor.close();
  });

  testWidgets('a restart reuses the stored key without registering again', (_) async {
    final sourcesBefore = await backendSources();
    final halvor = await start();
    expect(halvor.isReady, isTrue, reason: 'read from secure storage, no registration needed');
    expect(await backendSources(), sourcesBefore);
    pay(halvor, 'pi_it_3');
    await halvor.flush(timeout: const Duration(seconds: 10));
    expect((await backendEvents()).last['verified'], isTrue);
    await halvor.close();
  });

  testWidgets('going to the background sends the queue', (tester) async {
    final halvor = await start();
    final before = (await backendEvents()).length;
    pay(halvor, 'pi_it_background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect((await backendEvents()).length, before + 1,
        reason: 'sent on pause, not on the 1 h timer');
    await halvor.close();
  });

  testWidgets('offline batches are kept on disk and sent after a restart', (_) async {
    await admin('offline', {'offline': true});
    final first = await start(retryDelays: const [Duration.zero]);
    final before = (await backendEvents()).length;
    pay(first, 'pi_it_offline');
    await first.flush(timeout: const Duration(seconds: 10), replaySpool: false);
    expect(first.stats().spooled, 1);
    final spoolDir =
        Directory('${(await getApplicationSupportDirectory()).path}/halvorai/test/spool');
    expect(spoolDir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
        contains(matches(RegExp(r'^halvor-spool-\d{15}-[0-9a-f]{8}\.jsonl$'))));
    await first.close();

    await admin('offline', {'offline': false});
    final second = await start();
    await second.flush(timeout: const Duration(seconds: 10));
    expect((await backendEvents()).length, before + 1);
    expect(second.stats().replayed, 1);
    await second.close();
    errors.clear(); // the offline attempts were reported, as they should be
  });

  testWidgets('a request that hangs as the app leaves: the event survives the app being killed',
      (tester) async {
    final first = await start();
    final before = (await backendEvents()).length;
    await admin('hang', {'hang': true});
    pay(first, 'pi_it_hang');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(seconds: 1));

    // Well inside the OS's window, with the request still unanswered: the event is already safe.
    expect((await backendEvents()).length, before);
    final spoolDir =
        Directory('${(await getApplicationSupportDirectory()).path}/halvorai/test/spool');
    final spooled = spoolDir.listSync().whereType<File>().toList();
    expect(spooled, hasLength(1));
    expect(spooled.single.readAsStringSync(), contains('pi_it_hang'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    // The app is killed here: the first instance is left as it is and a new one starts.
    await admin('hang', {'hang': false});
    final second = await start();
    await second.flush(timeout: const Duration(seconds: 10));
    final events = await backendEvents();
    expect(events.length, before + 1);
    expect(events.last['verified'], isTrue);
    await second.close();
    await first.close(timeout: Duration.zero);
    errors.clear(); // the abandoned request was reported, as it should be
  });

  testWidgets('an x402 purchase records the challenge, payment and settlement', (_) async {
    final halvor = await start();
    final client = HalvorX402Client(halvor);
    final before = (await backendEvents()).length;
    final url = Uri.parse('$backend/premium-data');

    final response = await withAgentContext(agentContext, () async {
      final first = await client.get(url);
      final required = decodePaymentHeader(first.headers['payment-required']!);
      final accepted = ((required['accepts']! as List).first as Map).cast<String, Object?>();
      return client.get(url, headers: {
        'PAYMENT-SIGNATURE': encodePaymentHeader({
          'x402Version': 2,
          'resource': required['resource'],
          'accepted': accepted,
          'payload': {
            'signature': '0x${'ab' * 65}',
            'authorization': {
              'from': '0x857b06519E91e3A54538791bDbb0E22373e36b66',
              'to': accepted['payTo'],
              'value': accepted['amount'],
              'nonce': '0x${'cd' * 32}',
            },
          },
        }),
      });
    });
    await halvor.flush(timeout: const Duration(seconds: 10));

    expect(response.statusCode, 200);
    final events = (await backendEvents()).skip(before).toList();
    expect(events.map((e) => e['type']),
        ['payment.requested', 'payment.authorized', 'payment.settled']);
    expect(events[1]['payment_id'], events[2]['payment_id']);
    expect(events.every((e) => e['verified'] == true), isTrue);
    client.close();
    await halvor.close();
  });

  testWidgets('resetIdentity forgets the key; the next start registers a new one', (_) async {
    final old = await start();
    final oldId = old.sourceId;
    await old.resetIdentity();

    final fresh = await start();
    await ready(fresh);
    expect(fresh.sourceId, isNot(oldId));
    expect(await backendSources(), contains(fresh.sourceId));
    await fresh.close();
    expect(errors, isEmpty);
  });
}
