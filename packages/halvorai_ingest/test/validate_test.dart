// Tests mutate decoded JSON in place, where dynamic access is the point.
// ignore_for_file: avoid_dynamic_calls

// Which events are valid is decided by the shared cases in conformance_test.dart. These tests
// cover what the cases cannot: the messages, and Dart-specific details.

import 'dart:convert';

import 'package:halvorai_ingest/halvorai_ingest.dart';
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
  test('problems name the path and say what is wrong', () {
    expect(validateEvent(_mutate((e) => e['extra'] = 1)), ['(root): unrecognized key "extra"']);
    expect(
      validateEvent(_mutate((e) => e['payment']['status'] = 'failed')),
      ['payment.failure_reason: is required when status is failed'],
    );
    expect(
      validateEvent(_mutate((e) => e['payment']['amount']['value'] = '41.20')),
      ['payment.amount.value: must be a decimal integer string'],
    );
    expect(
      validateEvent(_mutate((e) => e['instruction'] = null)),
      ['instruction: expected object, received null'],
    );
  });

  test('a card number in a label key is not echoed in the error', () {
    final problems = validateEvent(_mutate((e) => e['labels'] = {'4242424242424242': 'v'}));
    expect(problems, ['labels: pan_detected in a key']);
  });

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
