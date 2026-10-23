/// Where signed envelopes go: straight to the HalvorAI API, or to your own backend, which
/// forwards them unchanged (the mobile setup, where the app never holds an API key).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A signed event as sent on the wire: `{"event": {...}, "sig": "<header>..<signature>"}`.
class SignedEnvelope {
  const SignedEnvelope(this.event, this.sig);

  factory SignedEnvelope.fromJson(Map<String, Object?> json) {
    final event = json['event'];
    final sig = json['sig'];
    if (event is! Map || sig is! String) {
      throw const FormatException('envelope needs an event object and a sig string');
    }
    return SignedEnvelope(event.cast<String, Object?>(), sig);
  }

  final Map<String, Object?> event;
  final String sig;

  String get id => event['id'] as String? ?? '';

  Map<String, Object?> toJson() => {'event': event, 'sig': sig};
}

/// The API's verdict on one event in a batch.
class IngestResult {
  const IngestResult(this.id, this.status, {this.serverCode});

  final String id;

  /// `accepted`, `duplicate` or `rejected`.
  final String status;
  final String? serverCode;
}

sealed class DeliveryOutcome {
  const DeliveryOutcome();
}

class DeliveryOk extends DeliveryOutcome {
  /// The API answers for each event; an event with no result counts as unconfirmed.
  const DeliveryOk(this.results) : perEvent = true;

  /// A destination with no per-event answers, such as a sink: every event counts as accepted.
  const DeliveryOk.unconfirmable()
      : results = const [],
        perEvent = false;

  final List<IngestResult> results;

  /// Whether [results] is expected to cover every event in the batch.
  final bool perEvent;
}

/// Worth retrying: network errors, timeouts, 408, 429 and 5xx.
class DeliveryRetry extends DeliveryOutcome {
  const DeliveryRetry(this.message, {this.status, this.serverCode});

  final String message;
  final int? status;
  final String? serverCode;
}

/// Retrying will not help: 400, 401, 403 or 422.
class DeliveryFatal extends DeliveryOutcome {
  const DeliveryFatal(this.status, this.message, {this.serverCode, this.details, this.requestId});

  final int status;
  final String message;
  final String? serverCode;
  final List<Object?>? details;
  final String? requestId;
}

/// 413: the client splits the batch and tries again.
class DeliveryTooLarge extends DeliveryOutcome {
  const DeliveryTooLarge();
}

/// Sends one batch. Implementations classify the result and never throw.
abstract interface class EventTransport {
  Future<DeliveryOutcome> send(List<SignedEnvelope> envelopes);

  /// Releases connections the transport owns.
  void close();
}

const productionEndpoint = 'https://api.halvorai.com';
const sandboxEndpoint = 'https://api.sandbox.halvorai.com';

final _apiKeyPattern = RegExp(r'^hk_(test|live)_[0-9A-Za-z]{32}$');

/// The environment a well-formed API key belongs to (`test` or `live`), or null.
String? apiKeyEnvironment(String key) => _apiKeyPattern.firstMatch(key)?[1];

/// Posts straight to `POST {endpoint}/v1/events` with an `hk_` key. For servers, and for
/// debug builds of an app; a shipped app should use [ForwardingTransport] instead.
class HalvorApiTransport implements EventTransport {
  /// [endpoint] is a base URL and defaults to the sandbox for `hk_test_` keys and production
  /// for `hk_live_` keys. A full `/v1/events` URL is accepted as is.
  HalvorApiTransport({
    required String apiKey,
    String? endpoint,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _apiKey = apiKey,
        _url = Uri.parse(eventsUrl(
          endpoint ?? (apiKeyEnvironment(apiKey) == 'live' ? productionEndpoint : sandboxEndpoint),
        )),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _timeout = timeout;

  final String _apiKey;
  final Uri _url;
  final http.Client _http;
  final bool _ownsHttp;
  final Duration _timeout;

  Uri get url => _url;

  @override
  Future<DeliveryOutcome> send(List<SignedEnvelope> envelopes) => postEnvelopes(
        _http,
        _url,
        {'authorization': 'Bearer $_apiKey'},
        envelopes,
        _timeout,
      );

  @override
  void close() {
    if (_ownsHttp) _http.close();
  }
}

/// Posts batches to your own backend, which checks the caller and forwards the body unchanged
/// to HalvorAI's `/v1/events`, returning HalvorAI's response.
///
/// The body is `{"events": [{"event": …, "sig": …}]}`. [headers] runs before every request,
/// so it can return a fresh session token.
class ForwardingTransport implements EventTransport {
  ForwardingTransport(
    this.url, {
    FutureOr<Map<String, String>> Function()? headers,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _headers = headers,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _timeout = timeout;

  final Uri url;
  final FutureOr<Map<String, String>> Function()? _headers;
  final http.Client _http;
  final bool _ownsHttp;
  final Duration _timeout;

  @override
  Future<DeliveryOutcome> send(List<SignedEnvelope> envelopes) async {
    final Map<String, String> headers;
    try {
      headers = await _headers?.call() ?? const {};
    } catch (e) {
      return DeliveryRetry('headers callback failed: $e');
    }
    return postEnvelopes(_http, url, headers, envelopes, _timeout);
  }

  @override
  void close() {
    if (_ownsHttp) _http.close();
  }
}

/// `endpoint` is a base URL; a full `/v1/events` URL is kept as is.
String eventsUrl(String endpoint) {
  final base = endpoint.replaceFirst(RegExp(r'/+$'), '');
  return base.endsWith('/v1/events') ? base : '$base/v1/events';
}

const _retryStatuses = {408, 429, 500, 502, 503, 504};
const _fatalStatuses = {400, 401, 403, 422};

/// Posts `{"events": [...]}` and classifies the response. Never throws.
Future<DeliveryOutcome> postEnvelopes(
  http.Client client,
  Uri url,
  Map<String, String> headers,
  List<SignedEnvelope> envelopes,
  Duration timeout,
) async {
  final http.Response response;
  try {
    response = await client
        .post(
          url,
          headers: {
            ...headers,
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: jsonEncode({
            'events': [for (final e in envelopes) e.toJson()]
          }),
        )
        .timeout(timeout);
  } catch (e) {
    return DeliveryRetry(e is TimeoutException ? 'request timed out' : 'network error: $e');
  }

  final status = response.statusCode;
  if (status == 413) return const DeliveryTooLarge();
  final error = _errorBody(response);
  if (_fatalStatuses.contains(status)) {
    return DeliveryFatal(
      status,
      error?.message ?? 'HTTP $status',
      serverCode: error?.code,
      details: error?.details,
      requestId: error?.requestId,
    );
  }
  if (_retryStatuses.contains(status) || status < 200 || status >= 300) {
    return DeliveryRetry(error?.message ?? 'HTTP $status', status: status, serverCode: error?.code);
  }

  // An empty 2xx (a backend answering 204) was received but confirms nothing; retrying it would
  // loop forever. A non-JSON body is still retried: on a phone it is often a captive portal.
  if (response.body.trim().isEmpty) return const DeliveryOk([]);
  try {
    final body = jsonDecode(response.body);
    final results = body is Map ? body['results'] : null;
    return DeliveryOk([
      if (results is List)
        for (final r in results)
          if (r is Map && r['id'] is String)
            IngestResult(
              r['id'] as String,
              r['status'] is String ? r['status'] as String : 'accepted',
              serverCode: switch (r['error']) {
                {'code': final String code} => code,
                _ => null,
              },
            ),
    ]);
  } catch (_) {
    return const DeliveryRetry('invalid response body');
  }
}

typedef _ErrorBody = ({String? code, String? message, List<Object?>? details, String? requestId});

/// `{"error": {"code", "message", "details", "request_id"}}`, as the API returns.
_ErrorBody? _errorBody(http.Response response) {
  try {
    final body = jsonDecode(response.body);
    if (body is! Map || body['error'] is! Map) return null;
    final e = body['error'] as Map;
    return (
      code: e['code'] is String ? e['code'] as String : null,
      message: e['message'] is String ? e['message'] as String : null,
      details: e['details'] is List ? (e['details'] as List).cast<Object?>() : null,
      requestId: e['request_id'] is String ? e['request_id'] as String : null,
    );
  } catch (_) {
    return null;
  }
}
