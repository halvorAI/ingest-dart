/// APE v0.1 validation before signing, so a malformed event is dropped and reported, never
/// sent. Mirrors the TypeScript SDK's zod model (`ingest-js/vendor/schema/ape.ts`), including
/// its strictness: unknown keys are errors, and an optional field must be absent, not null.
library;

import 'redact.dart' show containsPan;

typedef _Check = void Function(Object? value, String path, List<String> out);

/// Problems with [event] as `path: message` strings. Empty when the event is valid.
List<String> validateEvent(Map<String, Object?> event) {
  final out = <String>[];
  _event(event, '', out);
  if (out.isEmpty) _panGuard(event, out);
  return out;
}

String _at(String path, String key) => path.isEmpty ? key : '$path.$key';

void _fail(List<String> out, String path, String message) =>
    out.add('${path.isEmpty ? '(root)' : path}: $message');

// ---------------------------------------------------------------------------------------------
// Primitives

_Check _string(
        {int? min,
        int? max,
        RegExp? pattern,
        String? patternName,
        bool Function(String)? test,
        String? testName}) =>
    (value, path, out) {
      if (value is! String) return _fail(out, path, 'expected string, received ${_kind(value)}');
      if (min != null && value.length < min) {
        return _fail(out, path, 'must be at least $min characters');
      }
      if (max != null && value.length > max) {
        return _fail(out, path, 'must be at most $max characters');
      }
      if (pattern != null && !pattern.hasMatch(value)) {
        return _fail(out, path, 'must be ${patternName ?? 'well formed'}');
      }
      if (test != null && !test(value)) _fail(out, path, 'must be ${testName ?? 'well formed'}');
    };

_Check _max(int n) => _string(max: n);

_Check _enum(List<String> values) => (value, path, out) {
      if (value is! String || !values.contains(value)) {
        _fail(out, path, 'must be one of ${values.join(', ')}');
      }
    };

_Check _literal(String expected) => (value, path, out) {
      if (value != expected) _fail(out, path, 'must be "$expected"');
    };

_Check _int({required int min, required int max}) => (value, path, out) {
      if (value is! int) return _fail(out, path, 'expected integer, received ${_kind(value)}');
      if (value < min || value > max) _fail(out, path, 'must be between $min and $max');
    };

/// A rail reference: a string or an integer.
void _refValue(Object? value, String path, List<String> out) {
  if (value is! String && value is! int) {
    _fail(out, path, 'expected string or integer, received ${_kind(value)}');
  }
}

final _country = _string(pattern: RegExp(r'^[A-Z]{2}$'), patternName: 'an ISO 3166-1 alpha-2 code');
final _currency = _string(pattern: RegExp(r'^[A-Z]{3}$'), patternName: 'an ISO 4217 code');
final _caip2 = _string(
    pattern: RegExp(r'^[-a-z0-9]{3,8}:[-_a-zA-Z0-9]{1,32}$'), patternName: 'a CAIP-2 network id');
final _sha256 =
    _string(pattern: RegExp(r'^sha256:[0-9a-f]{64}$'), patternName: 'sha256:<64 lowercase hex>');
final _amountValue =
    _string(pattern: RegExp(r'^(0|[1-9][0-9]*)$'), patternName: 'a decimal integer string');
final _fourDigits = _string(pattern: RegExp(r'^[0-9]{4}$'), patternName: 'four digits');
final _url = _string(pattern: RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://\S+$'), patternName: 'a URL');
final _dateTime = _string(test: _isRfc3339, testName: 'an RFC 3339 date-time with an offset');

final _rfc3339 =
    RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-](\d{2}):(\d{2}))$');

bool _isRfc3339(String s) {
  final m = _rfc3339.firstMatch(s);
  if (m == null) return false;
  int g(int i) => int.parse(m[i]!);
  final year = g(1), month = g(2), day = g(3);
  if (month < 1 || month > 12 || day < 1) return false;
  if (day > DateTime.utc(year, month + 1, 0).day) return false;
  if (g(4) > 23 || g(5) > 59 || g(6) > 59) return false;
  if (m[9] != null && (g(9) > 23 || g(10) > 59)) return false;
  return true;
}

String _kind(Object? value) => switch (value) {
      null => 'null',
      String() => 'string',
      int() => 'integer',
      double() => 'number',
      bool() => 'boolean',
      List() => 'array',
      Map() => 'object',
      _ => value.runtimeType.toString(),
    };

// ---------------------------------------------------------------------------------------------
// Objects

/// A strict object: [required] and [optional] fields, nothing else. [refine] runs only when
/// the fields themselves are valid, as zod's `refine` does.
_Check _object(
  Map<String, _Check> required, {
  Map<String, _Check> optional = const {},
  void Function(Map<Object?, Object?> m, String path, List<String> out)? refine,
}) =>
    (value, path, out) {
      if (value is! Map) return _fail(out, path, 'expected object, received ${_kind(value)}');
      final before = out.length;
      for (final key in value.keys) {
        if (key is! String || (!required.containsKey(key) && !optional.containsKey(key))) {
          _fail(out, path, 'unrecognized key "$key"');
        }
      }
      required.forEach((key, check) {
        if (!value.containsKey(key)) return _fail(out, _at(path, key), 'is required');
        check(value[key], _at(path, key), out);
      });
      optional.forEach((key, check) {
        if (value.containsKey(key)) check(value[key], _at(path, key), out);
      });
      if (refine != null && out.length == before) refine(value, path, out);
    };

_Check _array(_Check item, {required int max}) => (value, path, out) {
      if (value is! List) return _fail(out, path, 'expected array, received ${_kind(value)}');
      if (value.length > max) _fail(out, path, 'must have at most $max items');
      for (var i = 0; i < value.length; i++) {
        item(value[i], _at(path, '$i'), out);
      }
    };

/// A discriminated union on [key].
_Check _union(String key, Map<String, _Check> variants) => (value, path, out) {
      if (value is! Map) return _fail(out, path, 'expected object, received ${_kind(value)}');
      final variant = variants[value[key]];
      if (variant == null) {
        return _fail(out, _at(path, key), 'must be one of ${variants.keys.join(', ')}');
      }
      variant(value, path, out);
    };

// ---------------------------------------------------------------------------------------------
// APE v0.1

final _source = _object({
  'id': _max(64),
  'sdk': _max(64),
  'adapter': _enum([
    'stripe',
    'stripe-issuing',
    'x402-client',
    'x402-server',
    'mpp-server',
    'mcp',
    'manual',
    'custom'
  ]),
});

final _agent = _object({
  'id': _max(128),
}, optional: {
  'name': _max(128),
  'framework': _max(64),
  'version': _max(64),
  'key_thumbprint': _max(64),
  'kya': _object({'provider': _max(64), 'subject': _max(256)},
      optional: {'assurance': _max(64), 'verified_at': _dateTime}),
});

final _owner = _object({
  'id': _max(128),
  'type': _enum(['person', 'business']),
}, optional: {
  'display_name': _max(128),
  'country': _country,
  'kyc_ref': _max(128),
});

final _instruction = _object({
  'id': _max(128),
  'hash': _sha256,
}, optional: {
  'summary': _max(500),
  'channel': _enum(['chat', 'api', 'schedule', 'email', 'agent', 'other']),
  'issued_at': _dateTime,
  'tool_call_id': _max(128),
});

final _asset = _object({
  'network': _caip2,
  'address': _max(128),
}, optional: {
  'symbol': _max(16),
  'decimals': _int(min: 0, max: 36),
});

final _amount = _union('unit', {
  'minor': _object({'value': _amountValue, 'unit': _literal('minor'), 'currency': _currency},
      optional: {'asset': _asset}),
  'atomic': _object({'value': _amountValue, 'unit': _literal('atomic'), 'asset': _asset},
      optional: {'currency': _currency}),
});

_Check _refs(List<String> keys) => _object({}, optional: {for (final k in keys) k: _refValue});

_Check _payment(String rail, List<String> refKeys) => _object(
      {
        'payment_id': _max(256),
        'rail': _literal(rail),
        'amount': _amount,
        'status': _enum(['requested', 'authorized', 'settled', 'failed', 'refunded', 'disputed']),
        'rail_ref': _refs(refKeys),
      },
      optional: {'failure_reason': _max(128), 'description': _max(256), 'category': _max(64)},
      refine: (m, path, out) {
        if (m['status'] == 'failed' && !m.containsKey('failure_reason')) {
          _fail(out, _at(path, 'failure_reason'), 'is required when status is failed');
        }
      },
    );

final _paymentUnion = _union('rail', {
  'stripe': _payment('stripe',
      ['account', 'payment_intent', 'charge', 'refund', 'dispute', 'shared_payment_token']),
  'card': _payment(
      'card', ['authorization_id', 'transaction_id', 'network_transaction_id', 'processor']),
  'x402':
      _payment('x402', ['scheme', 'network', 'nonce', 'tx_hash', 'facilitator', 'payment_flow']),
  'mpp': _payment('mpp', ['method', 'challenge_id', 'payment_intent', 'tx_hash']),
  'stablecoin': _payment('stablecoin', ['network', 'tx_hash', 'log_index']),
  'bank_transfer': _payment('bank_transfer', ['scheme', 'end_to_end_id', 'pisp']),
});

final _wallet = _object({'network': _caip2, 'address': _max(128)});

final _payee = _object(
  {
    'type': _enum(['merchant', 'api_provider', 'wallet', 'business', 'person'])
  },
  optional: {
    'name': _max(256),
    'id': _max(128),
    'website': _url,
    'country': _country,
    'mcc': _fourDigits,
    'wallet': _wallet,
    'resource_url': _url,
  },
  refine: (m, path, out) {
    if (!m.containsKey('name') && !m.containsKey('wallet') && !m.containsKey('id')) {
      _fail(out, path, 'payee needs at least one of name, wallet or id');
    }
  },
);

final _instrument = _object({
  'type': _enum(['card', 'agentic_token', 'stripe_spt', 'wallet', 'bank_account']),
}, optional: {
  'network': _max(32),
  'last4': _fourDigits,
  'par': _max(64),
  'token_ref': _max(128),
  'wallet': _wallet,
  'issuer': _max(128),
});

void _evidenceValue(Object? value, String path, List<String> out) {
  if (value is String) return;
  if (value is Map && value.keys.every((k) => k is String)) return;
  _fail(out, path, 'expected string or object, received ${_kind(value)}');
}

final _evidence = _object(
  {
    'kind': _enum([
      'ap2.payment_mandate',
      'ap2.checkout_mandate',
      'vi.chain',
      'tap.signature',
      'x402.payment_payload',
      'x402.settlement',
      'mpp.receipt',
      'stripe.object',
      'agentic_token.metadata',
      'kya.attestation',
    ]),
    'format': _enum(['sd-jwt', 'kb-sd-jwt', 'jws', 'http-signature', 'json']),
    'sha256': _sha256,
  },
  optional: {'value': _evidenceValue, 'uri': _url, 'captured_at': _dateTime},
  refine: (m, path, out) {
    if (m.containsKey('value') == m.containsKey('uri')) {
      _fail(out, path, 'evidence needs exactly one of value or uri');
    }
  },
);

final _related = _object({}, optional: {
  'previous_event_id': _max(128),
  'corrects_event_id': _max(128),
  'session_id': _max(128),
});

void _labels(Object? value, String path, List<String> out) {
  if (value is! Map) return _fail(out, path, 'expected object, received ${_kind(value)}');
  if (value.length > 20) _fail(out, path, 'at most 20 labels');
  value.forEach((key, label) {
    if (key is! String || key.length > 64) {
      _fail(out, path, 'label keys must be strings of at most 64 characters');
    }
    _max(256)(label, _at(path, '$key'), out);
  });
}

final _event = _object({
  'ape_version': _literal('0.1'),
  'id': _string(min: 8, max: 128),
  'type': _enum([
    'payment.requested',
    'payment.authorized',
    'payment.settled',
    'payment.failed',
    'payment.refunded',
    'payment.disputed'
  ]),
  'occurred_at': _dateTime,
  'environment': _enum(['test', 'live']),
  'source': _source,
  'agent': _agent,
  'owner': _owner,
  'payment': _paymentUnion,
  'payee': _payee,
}, optional: {
  'instruction': _instruction,
  'instrument': _instrument,
  'evidence': _array(_evidence, max: 16),
  'related': _related,
  'labels': _labels,
});

/// The card-number guard from the security spec, which JSON Schema cannot express.
void _panGuard(Map<String, Object?> event, List<String> out) {
  String? at(String a, String b) {
    final parent = event[a];
    final value = parent is Map ? parent[b] : null;
    return value is String ? value : null;
  }

  final texts = <String, String?>{
    'payment.description': at('payment', 'description'),
    'payment.category': at('payment', 'category'),
    'payment.failure_reason': at('payment', 'failure_reason'),
    'instruction.summary': at('instruction', 'summary'),
    'agent.name': at('agent', 'name'),
    'owner.display_name': at('owner', 'display_name'),
    'payee.name': at('payee', 'name'),
    // Beyond the zod model: URLs can carry anything in their query string.
    'payee.website': at('payee', 'website'),
    'payee.resource_url': at('payee', 'resource_url'),
    if (event['labels'] case final Map<Object?, Object?> labels)
      for (final e in labels.entries) 'labels.${e.key}': e.value as String?,
  };
  texts.forEach((path, text) {
    if (text != null && containsPan(text)) _fail(out, path, 'pan_detected');
  });
  // Label keys are free text too. The path leaves the key out so the error never echoes it.
  if (event['labels'] case final Map<Object?, Object?> labels) {
    if (labels.keys.any((k) => k is String && containsPan(k))) {
      _fail(out, 'labels', 'pan_detected in a key');
    }
  }
}
