import 'dart:convert';
import 'dart:io';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:halvorai_ingest/x402.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// The shared x402 fixtures (from ingest-js/src/x402/fixtures).
Map<String, Object?> fixture(String name) =>
    jsonDecode(File('test/fixtures/x402/$name.json').readAsStringSync()) as Map<String, Object?>;

/// What the Node.js mappers produce for the fixtures (tool/gen_x402_expected.mjs).
final expected = fixture('expected');

/// [event] as JSON with its generated id replaced, as the expected file has it.
Object? normalized(Map<String, Object?> event) {
  final id = event['id'];
  final text = jsonEncode(event);
  return jsonDecode(id is String ? text.replaceAll(id, 'evt_REQUESTED') : text);
}

void main() {
  group('decodePaymentHeader', () {
    test('reads standard and URL-safe base64, with or without padding', () {
      final value = {'a': 'b?>', 'n': 1};
      final standard = encodePaymentHeader(value);
      final urlSafe = standard.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      expect(decodePaymentHeader(standard), value);
      expect(decodePaymentHeader(' $urlSafe '), value);
    });

    test('refuses what is not a base64 JSON object', () {
      for (final bad in [
        '',
        '%%%',
        base64.encode(utf8.encode('not json')),
        encodePaymentHeader([1])
      ]) {
        expect(() => decodePaymentHeader(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('mappers match the Node.js SDK', () {
    final payload = fixture('payment-payload');
    final auth = (payload['payload']! as Map)['authorization'] as Map;
    final context = X402SettlementContext(
      accept: (payload['accepted']! as Map).cast<String, Object?>(),
      nonce: auth['nonce'] as String,
      resource: (payload['resource']! as Map).cast<String, Object?>(),
    );

    test('payment.requested', () {
      final mapped = mapPaymentRequired(fixture('payment-required'))!;
      expect(mapped['id'], startsWith('evt_'));
      expect(normalized(mapped), expected['requested']);
    });

    test('payment.authorized, linked to its challenge', () {
      final mapped = mapPaymentPayload(payload, previousEventId: 'evt_REQUESTED');
      expect(normalized(mapped!), expected['authorized']);
    });

    test('payment.settled', () {
      final mapped = mapSettlementResponse(fixture('settlement-success'), context: context);
      expect(normalized(mapped!), expected['settled']);
    });

    test('payment.failed', () {
      final mapped = mapSettlementResponse(fixture('settlement-failure'), context: context);
      expect(normalized(mapped!), expected['failed']);
    });

    test('a failed settlement gets a default reason, cut to 128 characters', () {
      final base = fixture('settlement-failure');
      Map<String, Object?> payment(Map<String, Object?> settlement) =>
          mapSettlementResponse(settlement, context: context)!['payment']! as Map<String, Object?>;

      final noReason = payment({...base}..remove('errorReason'));
      expect(noReason['failure_reason'], 'settlement_failed');
      expect(noReason['rail_ref'], isNot(contains('tx_hash')),
          reason: 'an empty transaction is left out');
      expect(payment({...base, 'errorReason': 'x' * 300})['failure_reason'], 'x' * 128);
    });

    test('a settlement without its payment is reported, not recorded', () {
      expect(
        () => mapSettlementResponse(fixture('settlement-success')),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', (expected['settledWithoutContext']! as Map)['throws'])),
      );
    });

    test('inside an agent context, agent and owner are left for the client to fill', () {
      final mapped = withAgentContext(
        const AgentContext(
          agent: AgentRef(id: 'agt_1', name: 'Research agent'),
          owner: OwnerRef(id: 'own_1', type: OwnerType.person),
        ),
        () => mapPaymentPayload(payload)!,
      );
      expect(mapped.containsKey('agent'), isFalse);
      expect(mapped.containsKey('owner'), isFalse);
    });

    test('a challenge without a network is refused, not guessed', () {
      final required = fixture('payment-required');
      final accept = Map<String, Object?>.of(((required['accepts']! as List).first as Map).cast())
        ..remove('network');
      expect(
        () => mapPaymentRequired({
          ...required,
          'accepts': [accept]
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('HalvorX402Client', () {
    late SourceKey key;
    late List<SignedEnvelope> sent;
    late List<SdkError> errors;
    late HalvorClient halvor;

    setUp(() async {
      key = await SourceKey.generate(kid: 'src_test');
      sent = [];
      errors = [];
      halvor = HalvorClient(
        sourceKey: key,
        environment: Environment.test,
        sink: sent.addAll,
        onError: errors.add,
      );
    });

    final requiredHeader = encodePaymentHeader(fixture('payment-required'));
    final signatureHeader = encodePaymentHeader(fixture('payment-payload'));
    final settlementHeader = encodePaymentHeader(fixture('settlement-success'));

    /// A resource server: 402 without a payment, 200 with settlement once paid.
    MockClient server({String? required, String? settlement}) => MockClient((request) async {
          if (request.headers['PAYMENT-SIGNATURE'] == null) {
            return http.Response('pay first', 402,
                headers: {'payment-required': required ?? requiredHeader});
          }
          return http.Response('{"price":42}', 200,
              headers: {'payment-response': settlement ?? settlementHeader});
        });

    /// What an x402 paying client does over the HTTP client it is given: try, read the 402, sign
    /// and retry. The signing is canned here; the fixture is a real x402 v2 payload.
    Future<http.Response> pay(http.Client client, Uri url) async {
      final first = await client.get(url);
      if (first.statusCode != 402) return first;
      return client.get(url, headers: {'PAYMENT-SIGNATURE': signatureHeader});
    }

    test('records the challenge, the payment and the settlement, linked together', () async {
      final client = HalvorX402Client(halvor, inner: server());
      final url = Uri.parse('https://api.example.com/premium-data');

      final response = await withAgentContext(
        const AgentContext(owner: OwnerRef(id: 'own_1', type: OwnerType.business)),
        () => pay(client, url),
      );
      await halvor.flush();

      expect(response.statusCode, 200);
      expect(response.body, '{"price":42}', reason: 'the response passes through unchanged');
      expect(errors, isEmpty);
      final events = [for (final e in sent) e.event];
      expect(events.map((e) => e['type']),
          ['payment.requested', 'payment.authorized', 'payment.settled']);
      final [requested, authorized, settled] = events;
      expect((authorized['related']! as Map)['previous_event_id'], requested['id']);
      expect((authorized['payment']! as Map)['payment_id'],
          (settled['payment']! as Map)['payment_id']);
      expect((requested['owner']! as Map)['id'], 'own_1', reason: 'filled from the context');
      for (final envelope in sent) {
        expect(validateEvent(envelope.event), isEmpty);
        expect(await verifyEvent(envelope.event, envelope.sig, key.publicJwk), isTrue);
      }
      final evidence = ((authorized['evidence']! as List).single as Map);
      expect(evidence['value'], fixture('payment-payload'), reason: 'payload kept verbatim');
    });

    test('traffic without x402 headers records nothing', () async {
      final client =
          HalvorX402Client(halvor, inner: MockClient((_) async => http.Response('plain', 200)));
      final response = await client.get(Uri.parse('https://example.com/'));
      await halvor.flush();
      expect(response.body, 'plain');
      expect(sent, isEmpty);
      expect(errors, isEmpty);
    });

    test('a header it cannot read is reported and the request still succeeds', () async {
      final client = HalvorX402Client(halvor, inner: server(required: '%%% not base64'));
      final response = await client.get(Uri.parse('https://api.example.com/premium-data'));
      await halvor.flush();
      expect(response.statusCode, 402);
      expect(sent, isEmpty);
      expect(errors.single.code, SdkErrorCode.invalidEvent);
      expect(errors.single.message, contains('PAYMENT-REQUIRED'));
    });

    test('a settlement without the payment that led to it is reported, not guessed', () async {
      final client = HalvorX402Client(halvor,
          inner: MockClient((_) async =>
              http.Response('ok', 200, headers: {'payment-response': settlementHeader})));
      await client.get(Uri.parse('https://api.example.com/premium-data'));
      await halvor.flush();
      expect(sent, isEmpty);
      expect(errors.single.message, contains('no asset'));
    });

    test('a payment for another URL is not linked to this challenge', () async {
      final client = HalvorX402Client(halvor, inner: server());
      await client.get(Uri.parse('https://api.example.com/premium-data'));
      await client.get(Uri.parse('https://api.example.com/other'),
          headers: {'PAYMENT-SIGNATURE': signatureHeader});
      await halvor.flush();
      final authorized =
          sent.map((e) => e.event).firstWhere((e) => e['type'] == 'payment.authorized');
      expect(authorized.containsKey('related'), isFalse);
    });

    test('works with HalvorFlutter or anything else that is a HalvorEmitter', () async {
      final emitted = <Map<String, Object?>>[];
      final client = HalvorX402Client(_RecordingEmitter(emitted), inner: server());
      await pay(client, Uri.parse('https://api.example.com/premium-data'));
      expect(emitted.map((e) => e['type']),
          ['payment.requested', 'payment.authorized', 'payment.settled']);
    });
  });
}

class _RecordingEmitter implements HalvorEmitter {
  _RecordingEmitter(this.events);

  final List<Map<String, Object?>> events;

  @override
  String emitJson(Map<String, Object?> event) {
    events.add(event);
    return (event['id'] as String?) ?? newEventId();
  }

  @override
  void notify(SdkError error) => fail('unexpected error: $error');
}
