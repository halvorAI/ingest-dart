// Tests mutate decoded JSON in place, where dynamic access is the point.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:halvorai_ingest/src/ids.dart';
import 'package:halvorai_ingest/src/time.dart';
import 'package:test/test.dart';

Map<String, Object?> validEvent() => {
      'ape_version': '0.1',
      'id': 'evt_01JA8Q4K3T9V2C7M5N6P8R0S1W',
      'type': 'payment.settled',
      'occurred_at': '2026-10-17T09:14:03.218Z',
      'environment': 'test',
      'source': {'id': 'src_local', 'sdk': 'halvorai_ingest@0.1.0', 'adapter': 'custom'},
      'agent': {'id': 'agt_travel_12'},
      'owner': {'id': 'own_u_4410', 'type': 'person'},
      'payment': {
        'payment_id': 'pi_3QxAbCdEfGhIjKlM',
        'rail': 'stripe',
        'amount': {'value': '41200', 'unit': 'minor', 'currency': 'USD'},
        'status': 'settled',
        'rail_ref': {'payment_intent': 'pi_3QxAbCdEfGhIjKlM'},
      },
      'payee': {'type': 'merchant', 'name': 'Example Airways'},
    };

Map<String, Object?> _mutate(void Function(Map<String, dynamic> e) change) {
  final event = jsonDecode(jsonEncode(validEvent())) as Map<String, dynamic>;
  change(event);
  return event;
}

void main() {
  test('a valid event has no problems', () {
    expect(validateEvent(validEvent()), isEmpty);
  });

  // The same cases the Python SDK checks, plus the strictness rules from the zod model.
  final rejects = <String, (void Function(Map<String, dynamic>), String)>{
    'failed without a reason': ((e) => e['payment']['status'] = 'failed', 'failure_reason'),
    'no rail_ref': ((e) => (e['payment'] as Map).remove('rail_ref'), 'rail_ref'),
    'payee with no name, wallet or id': ((e) => (e['payee'] as Map).remove('name'), 'payee'),
    'decimal amount': ((e) => e['payment']['amount']['value'] = '41.20', 'value'),
    'unknown type': ((e) => e['type'] = 'payment.approved', 'type'),
    'unknown key': ((e) => e['extra'] = 1, 'unrecognized key "extra"'),
    'null optional field': ((e) => e['instruction'] = null, 'instruction'),
    'wrong rail ref key': ((e) => e['payment']['rail_ref'] = {'nonce': 'n'}, 'nonce'),
    'lower-case currency': ((e) => e['payment']['amount']['currency'] = 'usd', 'currency'),
    'date without offset': ((e) => e['occurred_at'] = '2026-10-17T09:14:03', 'occurred_at'),
    'impossible date': ((e) => e['occurred_at'] = '2026-02-30T00:00:00Z', 'occurred_at'),
    'short id': ((e) => e['id'] = 'evt_1', 'id'),
    'atomic amount without asset': (
      (e) => e['payment']['amount'] = {'value': '1', 'unit': 'atomic'},
      'asset'
    ),
    'evidence with value and uri': (
      (e) => e['evidence'] = [
            {
              'kind': 'stripe.object',
              'format': 'json',
              'value': <String, Object?>{},
              'uri': 'https://x.test/a',
              'sha256': 'sha256:${'0' * 64}',
            }
          ],
      'exactly one of value or uri'
    ),
    'too many labels': ((e) => e['labels'] = {for (var i = 0; i < 21; i++) 'k$i': 'v'}, 'labels'),
    'card number in free text': (
      (e) => e['payee']['name'] = 'Pay 4242 4242 4242 4242',
      'pan_detected'
    ),
  };

  rejects.addAll({
    'card number in payee.website': (
      (e) => e['payee']['website'] = 'https://x.test/?c=4242424242424242',
      'payee.website: pan_detected'
    ),
    'card number in payee.resource_url': (
      (e) => e['payee']['resource_url'] = 'https://x.test/4242424242424242',
      'payee.resource_url: pan_detected'
    ),
    'card number in a label key': (
      (e) => e['labels'] = {'4242424242424242': 'v'},
      'labels: pan_detected in a key'
    ),
  });

  test('a card number in a label key is not echoed in the error', () {
    final problems = validateEvent(_mutate((e) => e['labels'] = {'4242424242424242': 'v'}));
    expect(problems.join(), isNot(contains('4242')));
  });

  test('identifiers are not checked for card numbers', () {
    final event = _mutate((e) {
      e['payment']['rail'] = 'card';
      e['payment']['rail_ref'] = {'network_transaction_id': '4242424242424242'};
    });
    expect(validateEvent(event), isEmpty);
  });

  for (final MapEntry(key: name, value: (change, where)) in rejects.entries) {
    test('rejects $name', () {
      final problems = validateEvent(_mutate(change));
      expect(problems.join('\n'), contains(where));
    });
  }

  test('accepts every rail with its own refs', () {
    final refs = {
      'card': {'authorization_id': 'iauth_1'},
      'x402': {'scheme': 'exact', 'network': 'eip155:8453', 'nonce': '0xabc'},
      'mpp': {'method': 'tempo'},
      'stablecoin': {'network': 'eip155:1', 'tx_hash': '0x1', 'log_index': 3},
      'bank_transfer': {'scheme': 'sepa', 'end_to_end_id': 'E2E1'},
    };
    refs.forEach((rail, ref) {
      final event = _mutate((e) {
        e['payment']['rail'] = rail;
        e['payment']['rail_ref'] = ref;
      });
      expect(validateEvent(event), isEmpty, reason: rail);
    });
  });

  test('ids and timestamps the SDK makes are valid', () {
    final id = newEventId();
    expect(RegExp(r'^evt_[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(id), isTrue);
    expect(newEventId().compareTo(id), greaterThan(0), reason: 'monotonic');
    final event = _mutate((e) {
      e['id'] = id;
      e['occurred_at'] = nowUtc();
    });
    expect(validateEvent(event), isEmpty);
  });
}
