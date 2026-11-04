import 'dart:async';

import 'package:http/http.dart' as http;

import '../client.dart';
import 'decode.dart';
import 'map.dart';

/// Challenges not yet answered by a payment. Bounded so it cannot grow forever.
const _maxPendingChallenges = 1000;

/// How long a challenge stays open when none of its options has a `maxTimeoutSeconds`.
const _defaultChallengeSeconds = 60;

/// What a payment copies from the option it picked, which identifies that option.
const _termFields = ['scheme', 'network', 'amount', 'asset', 'payTo'];

/// A `payment.requested` event waiting for the payment that answers it.
class _Challenge {
  _Challenge(this.url, this.eventId, this.options, this.expires) : zone = Zone.current;

  final String url;
  final String eventId;
  final List<Map<Object?, Object?>> options;
  final DateTime expires;

  /// The task that got the challenge. Its retry runs in the same zone.
  final Zone zone;

  /// Set once a payment could have answered this or another challenge. It is never linked after
  /// that: taking away the others doesn't show which one that payment answered.
  var ambiguous = false;

  bool offers(Map<Object?, Object?> accepted) =>
      options.any((option) => _termFields.every((f) => option[f] == accepted[f]));
}

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
///
/// x402 gives a challenge no id, so a payment is matched to its challenge by URL and terms, then
/// by zone: each `withAgentContext` is its own zone. If open challenges are still equally likely,
/// as with identical overlapping requests in one zone, the payment is recorded with no link
/// rather than a guessed one. Run concurrent purchases in their own `withAgentContext`.
class HalvorX402Client extends http.BaseClient {
  /// [halvor] is a `HalvorClient`, or `HalvorFlutter` in a Flutter app. [inner] sends the
  /// requests; it defaults to a new `http.Client`, and is closed with this one. [now] is for tests.
  HalvorX402Client(this._halvor, {http.Client? inner, DateTime Function() now = DateTime.now})
      : _inner = inner ?? http.Client(),
        _now = now;

  final HalvorEmitter _halvor;
  final http.Client _inner;
  final DateTime Function() _now;

  /// Challenges that have not been answered yet, oldest first.
  final _pending = <_Challenge>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final key = request.url.removeFragment().toString();

    Map<String, Object?>? payload;
    final signature = _header(request.headers, 'PAYMENT-SIGNATURE');
    if (signature != null) {
      _observe('PAYMENT-SIGNATURE', () {
        payload = decodePaymentHeader(signature);
        final candidates = _candidates(key, payload!);
        final link = candidates.length == 1 && !candidates.single.ambiguous
            ? candidates.single.eventId
            : null;
        final mapped = mapPaymentPayload(payload!, previousEventId: link);
        if (mapped == null) return;
        _halvor.emitJson(mapped);
        // Only now: a payment that could not be recorded leaves its challenge open.
        if (candidates.isEmpty) return;
        if (candidates.length > 1) {
          for (final challenge in candidates) {
            challenge.ambiguous = true;
          }
        }
        _pending.remove(candidates.first);
      });
    }

    final response = await _inner.send(request);

    if (response.statusCode == 402) {
      final required = _header(response.headers, 'PAYMENT-REQUIRED');
      if (required != null) {
        _observe('PAYMENT-REQUIRED', () {
          final challenge = decodePaymentHeader(required);
          final mapped = mapPaymentRequired(challenge);
          if (mapped == null) return;
          final id = _halvor.emitJson(mapped);
          final options =
              (challenge['accepts'] as List).whereType<Map<Object?, Object?>>().toList();
          _pending.add(_Challenge(key, id, options, _expiry(options)));
          if (_pending.length > _maxPendingChallenges) _pending.removeAt(0);
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

  /// The open challenges a payment to [url] may answer: those offering the terms it accepted, and
  /// of those, the ones from this task if there are any.
  List<_Challenge> _candidates(String url, Map<String, Object?> payload) {
    final now = _now();
    _pending.removeWhere((challenge) => !challenge.expires.isAfter(now));
    final accepted = payload['accepted'];
    if (accepted is! Map<Object?, Object?>) return const [];
    final matching = [
      for (final challenge in _pending)
        if (challenge.url == url && challenge.offers(accepted)) challenge,
    ];
    final own = [
      for (final challenge in matching)
        if (identical(challenge.zone, Zone.current)) challenge,
    ];
    return own.isEmpty ? matching : own;
  }

  /// A challenge can be paid until its longest option times out.
  DateTime _expiry(List<Map<Object?, Object?>> options) {
    var seconds = 0;
    for (final option in options) {
      if (option['maxTimeoutSeconds'] case final int s when s > seconds) seconds = s;
    }
    return _now().add(Duration(seconds: seconds > 0 ? seconds : _defaultChallengeSeconds));
  }

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
