import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:test/test.dart';

void main() {
  test('redacts Luhn-valid card numbers, with or without separators', () {
    expect(redactText('card 4242 4242 4242 4242 ok'), 'card [redacted:pan] ok');
    expect(redactText('4242-4242-4242-4242'), '[redacted:pan]');
    expect(redactText('4242424242424242'), '[redacted:pan]');
  });

  test('leaves numbers that are not card numbers', () {
    expect(redactText('order 1234567890123'), 'order 1234567890123');
    expect(redactText('amount 41200'), 'amount 41200');
  });

  test('redacts secret keys and private keys', () {
    expect(redactText('key sk_live_abc123XYZ end'), 'key [redacted:secret-key] end');
    expect(redactText('hk_test_${'a' * 32}'), '[redacted:secret-key]');
    expect(
      redactText('-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----'),
      '[redacted:private-key]',
    );
    expect(redactText('{"kty":"OKP","d":"secret"}'), '{"kty":"OKP","d":"[redacted:private-key]"}');
  });

  test('redacts CVCs and keeps the label', () {
    expect(redactText('cvc: 123'), 'cvc: [redacted:cvc]');
    expect(redactText('CVV2=4567'), 'CVV2=[redacted:cvc]');
    expect(redactText('{"cvc":"123"}'), '{"cvc":"[redacted:cvc]"}');
  });

  test('applies extra patterns with and without labels', () {
    final extras = [
      ExtraPattern(RegExp(r'ACCT-\d+'), label: 'account'),
      ExtraPattern(RegExp(r'secret')),
    ];
    expect(redactText('ACCT-991 secret', extraPatterns: extras), '[redacted:account] [redacted]');
  });

  test('redactDeep redacts every string and replaces private JWKs', () {
    final input = {
      'note': 'card 4242 4242 4242 4242',
      'list': ['sk_test_abc', 1, true, null],
      'key': {'kty': 'OKP', 'd': 'x'},
    };
    expect(redactDeep(input), {
      'note': 'card [redacted:pan]',
      'list': ['[redacted:secret-key]', 1, true, null],
      'key': '[redacted:private-key]',
    });
    expect(input['note'], 'card 4242 4242 4242 4242', reason: 'input is not changed');
  });

  test('redactDeep survives cycles and deep nesting', () {
    final cyclic = <String, Object?>{'a': 1};
    cyclic['self'] = cyclic;
    expect(redactDeep(cyclic), {'a': 1, 'self': '[circular]'});

    Object? deep = 'leaf';
    for (var i = 0; i < 100; i++) {
      deep = [deep];
    }
    expect(() => redactDeep(deep), returnsNormally);
  });

  test('the same object twice is not a cycle', () {
    final shared = {'v': 'x'};
    expect(redactDeep({'a': shared, 'b': shared}), {
      'a': {'v': 'x'},
      'b': {'v': 'x'},
    });
  });
}
