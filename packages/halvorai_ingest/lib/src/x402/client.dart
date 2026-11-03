import 'package:http/http.dart' as http;

import '../client.dart';
import 'decode.dart';
import 'map.dart';

/// Challenges not yet answered by a payment, per URL. Bounded so it cannot grow forever.
const _maxPendingChallenges = 1000;

/// A `package:http` client that records x402 payments as signed events, without taking part in
/// them: it only reads headers, and every request and response passes through unchanged.
///
/// Put it **under** the x402 client the agent pays with, as that client's HTTP client, so it sees
/// each request the x402 client makes: the first one, the 402 challenge (`PAYMENT-REQUIRED`), the
/// signed retry (`PAYMENT-SIGNATURE`) and the settlement (`PAYMENT-RESPONSE`). Wrapped around the
/// outside it would only see the final response.
///
/// A challenge becomes `payment.requested`; the payment that answers it becomes
/// `payment.authorized`, linked to it with `related.previous_event_id`; the settlement becomes
/// `payment.settled` or `payment.failed` with the same `payment_id`. A header that cannot be
/// decoded or mapped is reported through [HalvorEmitter.notify] and never breaks the request.
class HalvorX402Client extends http.BaseClient {
  /// [halvor] is a `HalvorClient`, or `HalvorFlutter` in a Flutter app. [inner] sends the
  /// requests; it defaults to a new `http.Client`, and is closed with this one.
  HalvorX402Client(this._halvor, {http.Client? inner}) : _inner = inner ?? http.Client();

  final HalvorEmitter _halvor;
  final http.Client _inner;

  /// The `payment.requested` event id for each URL whose 402 has not been answered yet, oldest
  /// first (a map literal keeps insertion order).
  final _requested = <String, String>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final key = request.url.removeFragment().toString();

    Map<String, Object?>? payload;
    final signature = _header(request.headers, 'PAYMENT-SIGNATURE');
    if (signature != null) {
      _observe('PAYMENT-SIGNATURE', () {
        payload = decodePaymentHeader(signature);
        final mapped = mapPaymentPayload(payload!, previousEventId: _requested.remove(key));
        if (mapped != null) _halvor.emitJson(mapped);
      });
    }

    final response = await _inner.send(request);

    if (response.statusCode == 402) {
      final required = _header(response.headers, 'PAYMENT-REQUIRED');
      if (required != null) {
        _observe('PAYMENT-REQUIRED', () {
          final mapped = mapPaymentRequired(decodePaymentHeader(required));
          if (mapped == null) return;
          final id = _halvor.emitJson(mapped);
          _requested
            ..remove(key)
            ..[key] = id;
          if (_requested.length > _maxPendingChallenges) _requested.remove(_requested.keys.first);
        });
      }
    }

    final settlement = _header(response.headers, 'PAYMENT-RESPONSE');
    if (settlement != null) {
      _observe('PAYMENT-RESPONSE', () {
        final paid = payload;
        final auth = paid?['payload'] is Map ? (paid!['payload'] as Map)['authorization'] : null;
        final nonce = auth is Map ? auth['nonce'] : null;
        final mapped = mapSettlementResponse(
          decodePaymentHeader(settlement),
          context: X402SettlementContext(
            accept: paid?['accepted'] is Map
                ? (paid!['accepted'] as Map).cast<String, Object?>()
                : null,
            nonce: nonce is String ? nonce : null,
            resource: paid?['resource'] is Map
                ? (paid!['resource'] as Map).cast<String, Object?>()
                : null,
          ),
        );
        if (mapped != null) _halvor.emitJson(mapped);
      });
    }

    return response;
  }

  @override
  void close() => _inner.close();

  /// Runs [body], reporting any failure as `invalid_event`: observing must never break a payment.
  void _observe(String header, void Function() body) {
    try {
      body();
    } catch (e) {
      _halvor.notify(SdkError(SdkErrorCode.invalidEvent, '$header: $e'));
    }
  }

  static String? _header(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == lower) return value;
    }
    return null;
  }
}
