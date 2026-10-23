import 'dart:convert';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _context = AgentContext(
  agent: AgentRef(id: 'agt_travel_12', name: 'Travel booking agent'),
  owner: OwnerRef(id: 'own_u_4410', type: OwnerType.person, country: 'US'),
  instruction: InstructionRef(id: 'task_8890', text: 'Book a return flight to Austin under \$500'),
);

EventInput _settled({String? id, String payeeName = 'Example Airways'}) => EventInput.settled(
      id: id,
      payment: const Payment(
        paymentId: 'pi_3QxAbCdEfGhIjKlM',
        amount: Amount.minor('41200', 'USD'),
        ref: StripeRef(paymentIntent: 'pi_3QxAbCdEfGhIjKlM'),
      ),
      payee: Payee.merchant(name: payeeName),
    );

const _fast = [Duration.zero, Duration.zero];

/// A transport that answers from a script of outcomes and records every batch.
class ScriptedTransport implements EventTransport {
  ScriptedTransport(this.script);

  final List<DeliveryOutcome Function(List<SignedEnvelope>)> script;
  final batches = <List<SignedEnvelope>>[];

  @override
  Future<DeliveryOutcome> send(List<SignedEnvelope> envelopes) async {
    batches.add(envelopes);
    final next = script.length > 1 ? script.removeAt(0) : script.single;
    return next(envelopes);
  }

  @override
  void close() {}
}

/// What the API answers when it keeps every event in the batch.
DeliveryOutcome _ok(List<SignedEnvelope> batch) =>
    DeliveryOk([for (final e in batch) IngestResult(e.id, 'accepted')]);

/// The same, as an HTTP response to a posted batch.
http.Response _acceptAll(http.Request request) {
  final events = (jsonDecode(request.body) as Map)['events'] as List;
  return http.Response(
    jsonEncode({
      'results': [
        for (final e in events) {'id': ((e as Map)['event'] as Map)['id'], 'status': 'accepted'}
      ]
    }),
    200,
  );
}

DeliveryOutcome _down(List<SignedEnvelope> _) => const DeliveryRetry('503', status: 503);

void main() {
  late SourceKey key;
  late List<SignedEnvelope> sent;
  late List<SdkError> errors;

  setUp(() async {
    key = await SourceKey.generate(kid: 'src_test');
    sent = [];
    errors = [];
  });

  HalvorClient offline({int batchSize = 100}) => HalvorClient(
        sourceKey: key,
        environment: Environment.test,
        sink: sent.addAll,
        onError: errors.add,
        batchSize: batchSize,
      );

  group('offline sink', () {
    test('signs a verifiable event attributed from the context', () async {
      final halvor = offline();
      final id = withAgentContext(_context, () => halvor.emit(_settled()));
      await halvor.flush();

      expect(errors, isEmpty);
      expect(sent, hasLength(1));
      final event = sent.single.event;
      expect(event['id'], id);
      expect(validateEvent(event), isEmpty);
      expect(await verifyEvent(event, sent.single.sig, key.publicJwk), isTrue);
      expect(event['source'], {'id': 'src_test', 'sdk': sdkName, 'adapter': 'custom'});
      expect((event['agent'] as Map)['name'], 'Travel booking agent');
      expect((event['owner'] as Map)['country'], 'US');
      expect((event['payment'] as Map)['status'], 'settled');
    });

    test('instruction text is hashed and never sent', () async {
      final halvor = offline();
      withAgentContext(_context, () => halvor.emit(_settled()));
      await halvor.flush();
      final instruction = sent.single.event['instruction'] as Map;
      expect(instruction['hash'], hashInstruction('Book a return flight to Austin under \$500'));
      expect(jsonEncode(sent), isNot(contains('Austin')));
    });

    test('without a context the event is unattributed', () async {
      final halvor = offline();
      halvor.emit(_settled());
      await halvor.flush();
      expect(sent.single.event['agent'], {'id': 'unattributed'});
      expect(sent.single.event['owner'], {'id': 'unattributed', 'type': 'business'});
    });

    test('card numbers are redacted before validation', () async {
      final halvor = offline();
      halvor.emit(_settled(payeeName: 'Airways card 4242 4242 4242 4242'));
      await halvor.flush();
      expect(errors, isEmpty);
      expect(jsonEncode(sent), isNot(contains('4242 4242')));
    });

    test('JSON evidence is redacted and re-hashed', () async {
      final halvor = offline();
      halvor.emitJson({
        ..._settled().toJson(),
        'evidence': [
          Evidence.json(EvidenceKind.stripeObject, {'note': 'sk_live_abc123'}).toJson(),
        ],
      });
      await halvor.flush();
      final evidence = (sent.single.event['evidence'] as List).single as Map;
      expect(evidence['value'], {'note': '[redacted:secret-key]'});
      expect(evidence['sha256'], evidenceSha256({'note': '[redacted:secret-key]'}));
    });

    test('an invalid event is dropped and reported, never signed', () async {
      final halvor = offline();
      halvor.emitJson({
        'type': 'payment.settled',
        'payment': {'amount': 'lots'}
      });
      await halvor.flush();
      expect(sent, isEmpty);
      expect(halvor.stats().droppedInvalid, 1);
      expect(errors.single.code, SdkErrorCode.invalidEvent);
      expect(errors.single.details, isNotEmpty);
    });

    test('emit never throws, even on values JSON cannot hold', () async {
      final halvor = offline();
      expect(
          () => halvor.emitJson({
                'type': 'payment.settled',
                'labels': {'x': DateTime(2026)}
              }),
          returnsNormally);
      await halvor.flush();
      expect(halvor.stats().droppedInvalid, 1);
    });

    test('a caller changing its map after emit does not change the event', () async {
      final halvor = offline();
      final input = _settled().toJson();
      halvor.emitJson(input);
      (input['payee'] as Map)['name'] = 'Changed';
      await halvor.flush();
      expect((sent.single.event['payee'] as Map)['name'], 'Example Airways');
    });

    test('a given id is kept', () async {
      final halvor = offline();
      expect(halvor.emit(_settled(id: 'evt_idempotent_1')), 'evt_idempotent_1');
      await halvor.flush();
      expect(sent.single.event['id'], 'evt_idempotent_1');
    });

    test('sends on its own after the flush interval', () async {
      final halvor = HalvorClient(
        sourceKey: key,
        environment: Environment.test,
        sink: sent.addAll,
        flushInterval: const Duration(milliseconds: 20),
      );
      halvor.emit(_settled());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sent, hasLength(1));
    });

    test('sends a full batch without waiting for the interval', () async {
      final halvor = offline(batchSize: 3);
      for (var i = 0; i < 3; i++) {
        halvor.emit(_settled());
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sent, hasLength(3));
    });

    test('close refuses later events', () async {
      final halvor = offline();
      halvor.emit(_settled());
      await halvor.close();
      halvor.emit(_settled());
      await halvor.flush();
      expect(sent, hasLength(1));
      expect(halvor.stats().droppedClosed, 1);
    });
  });

  group('configuration', () {
    test('needs exactly one destination', () {
      final none = HalvorClient(sourceKey: key, environment: Environment.test, onError: errors.add);
      expect(none.enabled, isFalse);
      final two = HalvorClient(
        sourceKey: key,
        environment: Environment.test,
        sink: (_) {},
        apiKey: 'hk_test_${'a' * 32}',
      );
      expect(two.enabled, isFalse);
      expect(errors.single.code, SdkErrorCode.config);
    });

    test('a sink or transport needs an environment', () {
      expect(HalvorClient(sourceKey: key, sink: (_) {}).enabled, isFalse);
    });

    test('a malformed or mismatched api key disables the client', () {
      expect(HalvorClient(sourceKey: key, apiKey: 'hk_test_short').enabled, isFalse);
      expect(
        HalvorClient(sourceKey: key, apiKey: 'hk_test_${'a' * 32}', environment: Environment.live)
            .enabled,
        isFalse,
      );
    });

    test('a disabled client counts what it drops and reports config once', () async {
      final halvor = HalvorClient(sourceKey: key, onError: errors.add);
      halvor
        ..emit(_settled())
        ..emit(_settled());
      expect(await halvor.flush(), isTrue);
      expect(halvor.stats().droppedDisabled, 2);
      expect(errors.where((e) => e.code == SdkErrorCode.config), hasLength(1));
    });

    test('test keys go to the sandbox, live keys to production', () {
      expect(HalvorApiTransport(apiKey: 'hk_test_${'a' * 32}').url.toString(),
          '$sandboxEndpoint/v1/events');
      expect(HalvorApiTransport(apiKey: 'hk_live_${'a' * 32}').url.toString(),
          '$productionEndpoint/v1/events');
      expect(
        HalvorApiTransport(apiKey: 'hk_test_${'a' * 32}', endpoint: 'http://localhost:8787/')
            .url
            .toString(),
        'http://localhost:8787/v1/events',
      );
    });
  });

  group('HTTP delivery', () {
    HalvorClient direct(MockClient http) => HalvorClient(
          sourceKey: key,
          transport: HalvorApiTransport(apiKey: 'hk_test_${'a' * 32}', httpClient: http),
          environment: Environment.test,
          onError: errors.add,
          retryDelays: _fast,
        );

    test('posts envelopes with the bearer key and counts each result', () async {
      late http.Request request;
      final halvor = direct(MockClient((r) async {
        request = r;
        final events = (jsonDecode(r.body) as Map)['events'] as List;
        final ids = [for (final e in events) ((e as Map)['event'] as Map)['id']];
        return http.Response(
          jsonEncode({
            'results': [
              {'id': ids[0], 'status': 'accepted'},
              {'id': ids[1], 'status': 'duplicate'},
              {
                'id': ids[2],
                'status': 'rejected',
                'error': {'code': 'environment_mismatch'}
              },
            ]
          }),
          200,
        );
      }));
      for (var i = 0; i < 3; i++) {
        halvor.emit(_settled());
      }
      await halvor.flush();

      expect(request.headers['authorization'], 'Bearer hk_test_${'a' * 32}');
      final stats = halvor.stats();
      expect([stats.accepted, stats.duplicates, stats.rejected], [1, 1, 1]);
      expect(errors.single.serverCode, 'environment_mismatch');
    });

    test('retries a 503 and then succeeds', () async {
      var calls = 0;
      final halvor =
          direct(MockClient((r) async => ++calls < 3 ? http.Response('down', 503) : _acceptAll(r)));
      halvor.emit(_settled());
      await halvor.flush();
      expect(calls, 3);
      expect(halvor.stats().retries, 2);
      expect(halvor.stats().accepted, 1);
    });

    test('a 401 is fatal and carries the server code', () async {
      final halvor = direct(MockClient((_) async => http.Response(
          jsonEncode({
            'error': {'code': 'unknown_source', 'message': 'no such source', 'request_id': 'req_1'}
          }),
          401)));
      halvor.emit(_settled());
      await halvor.flush();
      expect(halvor.stats().dropped, 1);
      expect(errors.single.code, SdkErrorCode.unauthorized);
      expect(errors.single.serverCode, 'unknown_source');
    });

    test('a 413 splits the batch', () async {
      final sizes = <int>[];
      final halvor = direct(MockClient((r) async {
        final n = ((jsonDecode(r.body) as Map)['events'] as List).length;
        sizes.add(n);
        return n > 1 ? http.Response('', 413) : _acceptAll(r);
      }));
      for (var i = 0; i < 3; i++) {
        halvor.emit(_settled());
      }
      await halvor.flush();
      expect(halvor.stats().accepted, 3);
      expect(sizes.first, 3);
    });
  });

  group('forwarding to your backend', () {
    test('posts to your URL with fresh headers and reads the forwarded results', () async {
      final seen = <http.Request>[];
      var token = 0;
      final halvor = HalvorClient(
        sourceKey: key,
        environment: Environment.live,
        transport: ForwardingTransport(
          Uri.parse('https://app.example/halvor/events'),
          headers: () => {'authorization': 'Bearer session_${++token}'},
          httpClient: MockClient((r) async {
            seen.add(r);
            return _acceptAll(r);
          }),
        ),
      );
      halvor.emit(_settled());
      await halvor.flush();
      halvor.emit(_settled());
      await halvor.flush();

      expect(seen.map((r) => r.url.toString()), everyElement('https://app.example/halvor/events'));
      expect(seen.map((r) => r.headers['authorization']), ['Bearer session_1', 'Bearer session_2']);
      final envelope = ((jsonDecode(seen.first.body) as Map)['events'] as List).single as Map;
      expect(envelope.keys, unorderedEquals(['event', 'sig']));
      expect((envelope['event'] as Map)['environment'], 'live');
    });
  });

  group('spool', () {
    HalvorClient spooled(ScriptedTransport transport, Spool spool) => HalvorClient(
          sourceKey: key,
          environment: Environment.test,
          transport: transport,
          spool: spool,
          onError: errors.add,
          retryDelays: _fast,
        );

    test('keeps a batch that ran out of retries and replays it later', () async {
      final spool = MemorySpool();
      final transport = ScriptedTransport([_down, _down, _down, _ok]);
      final halvor = spooled(transport, spool);
      halvor.emit(_settled());
      await halvor.flush(replaySpool: false);
      expect(halvor.stats().spooled, 1);
      expect(spool.length, 1);

      await halvor.flush();
      expect(spool.length, 0);
      expect(halvor.stats().replayed, 1);
      expect(halvor.stats().accepted, 1);
    });

    test('an entry the API refuses for good is removed and does not block the next', () async {
      final spool = MemorySpool();
      final good = SignedEnvelope({'id': 'evt_good_000001'}, 'sig');
      final bad = SignedEnvelope({'id': 'evt_bad_0000001'}, 'sig');
      await spool.write([bad]);
      await spool.write([good]);
      final transport = ScriptedTransport([
        (batch) => batch.single.id == bad.id
            ? const DeliveryFatal(422, 'bad', serverCode: 'invalid_signature')
            : _ok(batch),
      ]);
      final halvor = spooled(transport, spool);
      await halvor.flush();

      expect(spool.length, 0);
      expect(halvor.stats().dropped, 1, reason: 'counted once');
      expect(halvor.stats().accepted, 1);
      expect(errors.single.serverCode, 'invalid_signature');
    });

    test('a single event too large to send is dropped, never spooled', () async {
      final spool = MemorySpool();
      final halvor = spooled(ScriptedTransport([(_) => const DeliveryTooLarge()]), spool);
      halvor.emit(_settled());
      await halvor.flush();
      expect(spool.length, 0);
      expect(halvor.stats().dropped, 1);
      expect(errors.single.serverCode, 'payload_too_large');
    });

    test('without a spool, a batch that ran out of retries is dropped and reported', () async {
      final halvor = HalvorClient(
        sourceKey: key,
        environment: Environment.test,
        transport: ScriptedTransport([_down]),
        onError: errors.add,
        retryDelays: _fast,
      );
      halvor.emit(_settled());
      await halvor.flush();
      expect(halvor.stats().dropped, 1);
      expect(errors.single.code, SdkErrorCode.deliveryFailed);
    });
  });

  group('redaction beyond the zod free-text fields', () {
    test('label keys and payee URLs are redacted; identifiers are not', () async {
      final halvor = offline();
      final input = _settled().toJson();
      input['payee'] = {
        'type': 'api_provider',
        'name': 'Search API',
        'website': 'https://api.example/pay?card=4242424242424242',
        'resource_url': 'https://api.example/r?sk=sk_live_abc123',
      };
      input['labels'] = {'4242 4242 4242 4242': 'note'};
      // A Luhn-valid 15-digit network id, as card networks issue them: must survive.
      input['payment'] = {
        ...input['payment'] as Map<String, Object?>,
        'rail': 'card',
        'rail_ref': {'network_transaction_id': '123456789012347'},
      };
      halvor.emitJson(input);
      await halvor.flush();

      expect(errors, isEmpty);
      final event = sent.single.event;
      final payee = event['payee'] as Map;
      expect(payee['website'], 'https://api.example/pay?card=[redacted:pan]');
      expect(payee['resource_url'], 'https://api.example/r?sk=[redacted:secret-key]');
      expect(event['labels'], {'[redacted:pan]': 'note'});
      expect(((event['payment'] as Map)['rail_ref'] as Map)['network_transaction_id'],
          '123456789012347');
      expect(validateEvent(event), isEmpty);
    });
  });

  group('environment', () {
    test("an event can't claim a different environment than the client", () async {
      final halvor = offline();
      halvor.emitJson({..._settled().toJson(), 'environment': 'live'});
      await halvor.flush();
      expect(sent, isEmpty);
      expect(halvor.stats().droppedInvalid, 1);
      expect(errors.single.details!.single, contains('environment'));
    });

    test("an event repeating the client's environment is fine", () async {
      final halvor = offline();
      halvor.emitJson({..._settled().toJson(), 'environment': 'test'});
      await halvor.flush();
      expect(sent.single.event['environment'], 'test');
    });
  });

  group('per-event results', () {
    HalvorClient forwarding(MockClient http) => HalvorClient(
          sourceKey: key,
          environment: Environment.test,
          transport: ForwardingTransport(Uri.parse('https://app.example/e'), httpClient: http),
          onError: errors.add,
          retryDelays: _fast,
        );

    test('events missing from the response are unconfirmed, not accepted or retried', () async {
      var calls = 0;
      final halvor = forwarding(MockClient((_) async {
        calls++;
        return http.Response('{"ok":true}', 200);
      }));
      halvor
        ..emit(_settled())
        ..emit(_settled());
      await halvor.flush();
      halvor.emit(_settled());
      await halvor.flush();

      expect(calls, 2, reason: 'no retries');
      expect(halvor.stats().accepted, 0);
      expect(halvor.stats().unconfirmed, 3);
      expect(errors.where((e) => e.code == SdkErrorCode.config), hasLength(1),
          reason: 'reported once');
    });

    test('an empty 2xx body counts as unconfirmed instead of looping', () async {
      var calls = 0;
      final halvor = forwarding(MockClient((_) async {
        calls++;
        return http.Response('', 204);
      }));
      halvor.emit(_settled());
      await halvor.flush();
      expect(calls, 1);
      expect(halvor.stats().unconfirmed, 1);
    });

    test('a non-JSON 2xx body, such as a captive portal page, is retried', () async {
      var calls = 0;
      final halvor = forwarding(MockClient((r) async =>
          ++calls == 1 ? http.Response('<html>Sign in to Wi-Fi</html>', 200) : _acceptAll(r)));
      halvor.emit(_settled());
      await halvor.flush();
      expect(calls, 2);
      expect(halvor.stats().accepted, 1);
    });

    test('a sink has no per-event results, so its events count as accepted', () async {
      final halvor = offline();
      halvor.emit(_settled());
      await halvor.flush();
      expect(halvor.stats().accepted, 1);
      expect(halvor.stats().unconfirmed, 0);
    });
  });

  test('flush with a timeout returns false when delivery is still running', () async {
    final halvor = HalvorClient(
      sourceKey: key,
      environment: Environment.test,
      transport: ScriptedTransport([_down]),
      retryDelays: const [Duration(seconds: 5)],
    );
    halvor.emit(_settled());
    expect(await halvor.flush(timeout: const Duration(milliseconds: 50)), isFalse);
    halvor.dispose();
  });
}
