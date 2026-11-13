/// Maps x402 v2 HTTP payloads to partial APE events, the same as the Node.js and Python SDKs
/// (`ingest-js/src/x402/map.ts`) and ape-schema MAPPINGS §5.1. Checked against the Node.js output
/// for the shared fixtures in test/fixtures/x402.
library;

import '../context.dart';
import '../hash.dart';
import '../ids.dart';

/// `x402-client` (the paying side) or `x402-server` (the side charging).
typedef X402Adapter = String;

/// What the settlement mapper knows from the request that paid: the accepted requirement, the
/// payer's nonce and the resource.
class X402SettlementContext {
  const X402SettlementContext({this.accept, this.nonce, this.resource, this.payeeOverride});

  final Map<String, Object?>? accept;
  final String? nonce;
  final Map<String, Object?>? resource;
  final Map<String, Object?>? payeeOverride;
}

String? _str(Map<String, Object?>? m, String key) {
  final v = m?[key];
  return v is String ? v : null;
}

Map<String, Object?>? _map(Map<String, Object?>? m, String key) {
  final v = m?[key];
  return v is Map ? v.cast<String, Object?>() : null;
}

String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

/// The URL's host, with the port when it is not the scheme's default (as JavaScript's URL.host).
String? _host(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;
  final defaultPort = switch (uri.scheme) { 'http' => 80, 'https' => 443, _ => -1 };
  return uri.hasPort && uri.port != defaultPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// Throws when the network or asset is missing: guessing them would record wrong compliance data.
Map<String, Object?> _asset(Map<String, Object?> accept) {
  final network = _str(accept, 'network');
  final address = _str(accept, 'asset');
  if (network == null) {
    throw ArgumentError('x402 payment requirement has no network; event not recorded');
  }
  if (address == null) {
    throw ArgumentError('x402 payment requirement has no asset; event not recorded');
  }
  final extra = _map(accept, 'extra');
  final name = _str(extra, 'name');
  final decimals = extra?['decimals'];
  return {
    'network': network,
    'address': address,
    if (name != null) 'symbol': _cut(name, 16),
    if (decimals is num) 'decimals': decimals,
  };
}

Map<String, Object?> _amount(Map<String, Object?> accept, [String? override]) => {
      'value': override ?? _str(accept, 'amount') ?? '0',
      'unit': 'atomic',
      'asset': _asset(accept),
    };

/// Agent and owner for a mapped event. When the caller set them with `withAgentContext`, they are
/// left out so the client fills the full context (name, framework, country, …) at emit time.
Map<String, Object?> _attribution([String? payerWallet]) {
  final ctx = currentContext();
  return {
    if (ctx?.agent == null) 'agent': {'id': payerWallet ?? 'unattributed'},
    if (ctx?.owner == null) 'owner': {'id': 'unattributed', 'type': 'business'},
  };
}

Map<String, Object?> _payee(
  Map<String, Object?> accept,
  Map<String, Object?>? resource, [
  Map<String, Object?>? override,
]) {
  if (override != null) return {...override};
  final url = _str(resource, 'url');
  final name = _str(resource, 'serviceName') ?? _str(resource, 'description') ?? _host(url);
  final payTo = _str(accept, 'payTo');
  final network = _str(accept, 'network');
  final payee = <String, Object?>{
    'type': url != null ? 'api_provider' : 'wallet',
    if (name != null) 'name': _cut(name, 256),
    if (url != null) 'resource_url': url,
    if (payTo != null && network != null) 'wallet': {'network': network, 'address': payTo},
  };
  if (!payee.containsKey('name') && !payee.containsKey('wallet')) payee['name'] = 'x402 payee';
  return payee;
}

Map<String, Object?> _railRef(Map<String, Object?> accept, [Map<String, Object?>? extra]) {
  final flow = _str(_map(accept, 'extra'), 'paymentFlow');
  return {
    if (_str(accept, 'scheme') case final scheme?) 'scheme': scheme,
    if (_str(accept, 'network') case final network?) 'network': network,
    if (flow != null) 'payment_flow': flow,
    ...?extra,
  };
}

void _describe(Map<String, Object?> payment, Map<String, Object?>? resource) {
  final description = _str(resource, 'description');
  if (description != null) payment['description'] = _cut(description, 256);
}

/// A 402 challenge (`PAYMENT-REQUIRED`) as `payment.requested`, or null without an `accepts`.
///
/// The event carries its own `id`, and its `payment_id` is `x402:<network>:requested:<id>`: the
/// payer's nonce does not exist yet. Throws [ArgumentError] when the requirement has no network
/// or asset.
Map<String, Object?>? mapPaymentRequired(
  Map<String, Object?> required, {
  X402Adapter adapter = 'x402-client',
  Map<String, Object?>? payeeOverride,
}) {
  final accepts = required['accepts'];
  if (accepts is! List || accepts.isEmpty || accepts.first is! Map) return null;
  final accept = (accepts.first as Map).cast<String, Object?>();
  final resource = _map(required, 'resource');
  final id = newEventId();
  final payment = <String, Object?>{
    'payment_id': 'x402:${_str(accept, 'network') ?? 'unknown'}:requested:$id',
    'rail': 'x402',
    'amount': _amount(accept),
    'status': 'requested',
    'rail_ref': _railRef(accept),
  };
  _describe(payment, resource);
  return {
    'id': id,
    'type': 'payment.requested',
    'source': {'adapter': adapter},
    ..._attribution(),
    'payment': payment,
    'payee': _payee(accept, resource, payeeOverride),
    'evidence': <Object?>[],
  };
}

/// A signed payment (`PAYMENT-SIGNATURE`) as `payment.authorized`, or null without `accepted`.
///
/// [previousEventId] is the `payment.requested` event this payment answers, when the 402 for the
/// same URL was seen; it becomes `related.previous_event_id`. The payload is attached verbatim as
/// `x402.payment_payload` evidence. Throws [ArgumentError] without a network or asset.
Map<String, Object?>? mapPaymentPayload(
  Map<String, Object?> payload, {
  X402Adapter adapter = 'x402-client',
  Map<String, Object?>? payeeOverride,
  String? previousEventId,
}) {
  final accept = _map(payload, 'accepted');
  if (accept == null) return null;
  final auth = _map(_map(payload, 'payload'), 'authorization');
  final nonce = _str(auth, 'nonce') ?? 'unknown';
  final network = _str(accept, 'network');
  final payer = _str(auth, 'from');
  final payment = <String, Object?>{
    'payment_id': 'x402:${network ?? 'unknown'}:$nonce',
    'rail': 'x402',
    'amount': _amount(accept, _str(auth, 'value')),
    'status': 'authorized',
    'rail_ref': _railRef(accept, {'nonce': nonce}),
  };
  final resource = _map(payload, 'resource');
  _describe(payment, resource);
  return {
    'type': 'payment.authorized',
    'source': {'adapter': adapter},
    ..._attribution(payer),
    'payment': payment,
    'payee': _payee(accept, resource, payeeOverride),
    if (payer != null && network != null)
      'instrument': {
        'type': 'wallet',
        'wallet': {'network': network, 'address': payer},
      },
    if (previousEventId != null) 'related': {'previous_event_id': previousEventId},
    'evidence': [
      {
        'kind': 'x402.payment_payload',
        'format': 'json',
        'value': payload,
        'sha256': evidenceSha256(payload),
      },
    ],
  };
}

/// A settlement (`PAYMENT-RESPONSE`) as `payment.settled` or `payment.failed`.
///
/// It shares `x402:<network>:<nonce>` with the authorized event, and the transaction hash goes in
/// `rail_ref.tx_hash`. Without the paying request's [context] the settlement has no token address,
/// so this throws [ArgumentError] and the event is reported, not recorded.
Map<String, Object?>? mapSettlementResponse(
  Map<String, Object?> settlement, {
  X402SettlementContext context = const X402SettlementContext(),
  X402Adapter adapter = 'x402-client',
}) {
  final accept = <String, Object?>{'scheme': 'exact'};
  if (context.accept != null) {
    accept.addAll(context.accept!);
  } else {
    if (_str(settlement, 'network') case final network?) accept['network'] = network;
    if (_str(settlement, 'amount') case final amount?) accept['amount'] = amount;
  }
  final network = _str(settlement, 'network') ?? _str(accept, 'network') ?? 'unknown';
  final success = settlement['success'] == true;
  final transaction = _str(settlement, 'transaction');
  final payer = _str(settlement, 'payer');
  final payment = <String, Object?>{
    'payment_id': 'x402:$network:${context.nonce ?? 'unknown'}',
    'rail': 'x402',
    'amount': _amount(accept, _str(settlement, 'amount') ?? _str(accept, 'amount')),
    'status': success ? 'settled' : 'failed',
    'rail_ref': _railRef(accept, {
      if (context.nonce != null) 'nonce': context.nonce,
      if (transaction != null && transaction.isNotEmpty) 'tx_hash': transaction,
    }),
    if (!success)
      'failure_reason': _cut(_str(settlement, 'errorReason') ?? 'settlement_failed', 128),
  };
  _describe(payment, context.resource);
  return {
    'type': success ? 'payment.settled' : 'payment.failed',
    'source': {'adapter': adapter},
    ..._attribution(payer),
    'payment': payment,
    'payee': _payee(accept, context.resource, context.payeeOverride),
    if (payer != null && network != 'unknown')
      'instrument': {
        'type': 'wallet',
        'wallet': {'network': network, 'address': payer},
      },
    'evidence': [
      {
        'kind': 'x402.settlement',
        'format': 'json',
        'value': settlement,
        'sha256': evidenceSha256(settlement),
      },
    ],
  };
}
