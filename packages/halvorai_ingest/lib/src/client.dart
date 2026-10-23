/// HalvorClient: queue, build, redact, validate, sign, batch and deliver. `emit` never throws
/// and never waits on the network.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'context.dart';
import 'hash.dart';
import 'ids.dart';
import 'models.dart';
import 'redact.dart';
import 'sign.dart';
import 'spool.dart';
import 'time.dart';
import 'transport.dart';
import 'validate.dart';
import 'version.dart';

enum SdkErrorCode {
  invalidEvent('invalid_event'),
  unauthorized('unauthorized'),
  deliveryFailed('delivery_failed'),
  rejected('rejected'),
  spool('spool'),
  config('config');

  const SdkErrorCode(this.wire);

  /// The same code the Node.js and Python SDKs report.
  final String wire;
}

/// Something the client could not do. Delivered to `onError`; the client never throws.
class SdkError {
  const SdkError(this.code, this.message, {this.eventId, this.serverCode, this.details});

  final SdkErrorCode code;
  final String message;
  final String? eventId;

  /// The API's error code (`unknown_source`, `invalid_signature`, …) when it sent one.
  final String? serverCode;
  final List<Object?>? details;

  @override
  String toString() => [
        'SdkError(${code.wire}: $message',
        if (eventId != null) ', event: $eventId',
        if (serverCode != null) ', server: $serverCode',
        ')',
      ].join();
}

/// Counters since the client was created.
class ClientStats {
  const ClientStats({
    this.emitted = 0,
    this.queued = 0,
    this.accepted = 0,
    this.duplicates = 0,
    this.unconfirmed = 0,
    this.rejected = 0,
    this.dropped = 0,
    this.droppedInvalid = 0,
    this.droppedDisabled = 0,
    this.droppedClosed = 0,
    this.retries = 0,
    this.spooled = 0,
    this.replayed = 0,
  });

  final int emitted;

  /// Waiting in memory to be sent.
  final int queued;

  /// Confirmed by the API (or handed to a sink).
  final int accepted;
  final int duplicates;

  /// Delivered with a 2xx, but the response had no result for them, so whether the API kept
  /// them is unknown. Usually a forwarding backend that does not pass the response through.
  final int unconfirmed;

  /// Refused by the API, one by one.
  final int rejected;

  /// Given up on after a fatal response, or after retries with no spool to keep them.
  final int dropped;
  final int droppedInvalid;
  final int droppedDisabled;
  final int droppedClosed;
  final int retries;
  final int spooled;

  /// Taken out of the spool and settled (accepted, duplicate, rejected or dropped).
  final int replayed;
}

class _Counters {
  int emitted = 0;
  int accepted = 0;
  int duplicates = 0;
  int unconfirmed = 0;
  int rejected = 0;
  int dropped = 0;
  int droppedInvalid = 0;
  int droppedDisabled = 0;
  int droppedClosed = 0;
  int retries = 0;
  int spooled = 0;
  int replayed = 0;
}

/// Receives signed envelopes instead of the API, for offline use and tests. Throwing makes
/// the client retry the batch.
typedef EnvelopeSink = FutureOr<void> Function(List<SignedEnvelope> envelopes);

typedef ErrorHandler = void Function(SdkError error);

/// Backoff between delivery attempts; each delay gets up to 20 % jitter.
const defaultRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 32),
];

class _Pending {
  _Pending(this.id, this.input, this.context);

  final String id;
  final Map<String, Object?> input;
  final AgentContext? context;
}

class _SinkTransport implements EventTransport {
  _SinkTransport(this._sink);

  final EnvelopeSink _sink;

  @override
  Future<DeliveryOutcome> send(List<SignedEnvelope> envelopes) async {
    try {
      await _sink(envelopes);
      return const DeliveryOk.unconfirmable();
    } catch (e) {
      return DeliveryRetry('sink failed: $e');
    }
  }

  @override
  void close() {}
}

/// Records each payment an agent makes as a signed APE event. It is never in the payment
/// path: [emit] returns at once and never throws, and delivery happens in the background.
///
/// Give exactly one destination: [sink] (offline), [transport] (for example a
/// [ForwardingTransport] to your backend) or [apiKey] (straight to HalvorAI, for servers and
/// debug builds). A bad configuration disables the client and reports a `config` error once.
class HalvorClient {
  HalvorClient({
    required SourceKey sourceKey,
    Environment? environment,
    String? apiKey,
    String? endpoint,
    EventTransport? transport,
    EnvelopeSink? sink,
    Spool? spool,
    ErrorHandler? onError,
    List<ExtraPattern> redactPatterns = const [],
    int batchSize = 100,
    Duration flushInterval = const Duration(seconds: 1),
    List<Duration> retryDelays = defaultRetryDelays,
  })  : _key = sourceKey,
        _spool = spool,
        _onError = onError,
        _redactPatterns = redactPatterns,
        _batchSize = max(1, batchSize),
        _flushInterval = flushInterval,
        _retryDelays = retryDelays,
        _zone = Zone.current {
    final destinations = [sink, transport, apiKey].where((d) => d != null).length;
    if (destinations != 1) {
      _disable(destinations == 0
          ? 'no destination: pass sink, transport or apiKey'
          : 'pass only one of sink, transport or apiKey');
    } else if (sink != null || transport != null) {
      _transport = transport ?? _SinkTransport(sink!);
      _environment = environment;
      if (environment == null) _disable('environment is required with a sink or transport');
    } else {
      final keyEnv = apiKeyEnvironment(apiKey!);
      if (keyEnv == null) {
        _disable('api key is malformed (expected hk_test_… or hk_live_…)');
      } else if (environment != null && environment.wire != keyEnv) {
        _disable('environment ${environment.wire} does not match the $keyEnv api key');
      } else {
        _environment = environment ?? Environment.values.byName(keyEnv);
        _transport = HalvorApiTransport(apiKey: apiKey, endpoint: endpoint);
      }
    }
    if (!_disabled && spool != null) {
      _replayRequested = true;
      _zone.run(() => Timer.run(_kick));
    }
  }

  final SourceKey _key;
  final Spool? _spool;
  final ErrorHandler? _onError;
  final List<ExtraPattern> _redactPatterns;
  final int _batchSize;
  final Duration _flushInterval;
  final List<Duration> _retryDelays;

  /// Timers and delivery run in the zone the client was made in, not the caller's.
  final Zone _zone;

  EventTransport? _transport;
  Environment? _environment;

  final _counters = _Counters();
  final _raw = <_Pending>[];
  final _ready = <SignedEnvelope>[];
  final _random = Random();

  bool _disabled = false;
  bool _closed = false;
  bool _configReported = false;
  bool _unconfirmedReported = false;
  String? _configMessage;
  Timer? _timer;
  Future<void>? _draining;
  bool _rerun = false;
  bool _replayRequested = false;
  DateTime _spoolCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// False when the configuration was rejected; every emit is then counted and dropped.
  bool get enabled => !_disabled;

  ClientStats stats() => ClientStats(
        emitted: _counters.emitted,
        queued: _raw.length + _ready.length,
        accepted: _counters.accepted,
        duplicates: _counters.duplicates,
        unconfirmed: _counters.unconfirmed,
        rejected: _counters.rejected,
        dropped: _counters.dropped,
        droppedInvalid: _counters.droppedInvalid,
        droppedDisabled: _counters.droppedDisabled,
        droppedClosed: _counters.droppedClosed,
        retries: _counters.retries,
        spooled: _counters.spooled,
        replayed: _counters.replayed,
      );

  /// Queues [event] and returns its id. Agent, owner and instruction come from the current
  /// [AgentContext] unless the event sets them.
  String emit(EventInput event) {
    try {
      return emitJson(event.toJson());
    } catch (e) {
      // toJson can only fail on a broken custom value; never let it reach the caller.
      final id = event.id ?? newEventId();
      _counters
        ..emitted += 1
        ..droppedInvalid += 1;
      _report(SdkError(SdkErrorCode.invalidEvent, 'emit failed: $e', eventId: id));
      return id;
    }
  }

  /// Queues a partial event given as JSON, in the same shape the Node.js and Python SDKs
  /// take. Adapters use this.
  String emitJson(Map<String, Object?> event) {
    var id = newEventId();
    try {
      _counters.emitted += 1;
      if (_closed) {
        _counters.droppedClosed += 1;
        return id;
      }
      if (_disabled) {
        _counters.droppedDisabled += 1;
        _reportConfigOnce();
        return id;
      }
      final given = event['id'];
      if (given is String) id = given;
      _raw.add(_Pending(id, _copy(event) as Map<String, Object?>, currentContext()));
      if (_raw.length + _ready.length >= _batchSize) {
        _zone.run(() => Timer.run(_kick));
      } else {
        _scheduleFlush();
      }
      return id;
    } catch (e) {
      _counters.droppedInvalid += 1;
      _report(SdkError(SdkErrorCode.invalidEvent, 'emit failed: $e', eventId: id));
      return id;
    }
  }

  /// Sends everything queued, retrying as configured. With [timeout], gives up waiting (but
  /// not sending) after that long and returns false. With [replaySpool], also re-sends
  /// spooled batches now instead of waiting for the backoff.
  Future<bool> flush({Duration? timeout, bool replaySpool = true}) async {
    _timer?.cancel();
    _timer = null;
    if (replaySpool && _spool != null && !_disabled) {
      _spoolCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _replayRequested = true;
    }
    Future<void> drain() async {
      do {
        await _kick();
      } while (_raw.isNotEmpty || _ready.isNotEmpty);
    }

    if (timeout == null) {
      await drain();
      return true;
    }
    final finished = await drain().then((_) => true).timeout(timeout, onTimeout: () => false);
    return finished && _raw.isEmpty && _ready.isEmpty;
  }

  /// Refuses new events and stops the timer, without waiting for delivery.
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Refuses new events and sends what is queued. Spooled batches stay for the next start.
  Future<bool> close({Duration? timeout}) async {
    dispose();
    final drained = await flush(timeout: timeout, replaySpool: false);
    _transport?.close();
    return drained;
  }

  /// For adapters: report a decode or mapping failure. Never throws.
  void notify(SdkError error) => _report(error);

  // -------------------------------------------------------------------------------------------
  // Scheduling

  /// At most one pending timer: a steady trickle of events still goes out every interval.
  void _scheduleFlush() {
    if (_timer != null || _closed || _disabled) return;
    _timer = _zone.run(() => Timer(_flushInterval, () {
          _timer = null;
          unawaited(_kick());
        }));
  }

  Future<void> _kick() {
    final running = _draining;
    if (running != null) {
      _rerun = true;
      return running;
    }
    final drain = _zone.run(_drainLoop).whenComplete(() {
      _draining = null;
      if (_raw.isNotEmpty || _ready.isNotEmpty) _scheduleFlush();
    });
    _draining = drain;
    return drain;
  }

  Future<void> _drainLoop() async {
    do {
      _rerun = false;
      if (_replayRequested) {
        _replayRequested = false;
        await _replaySpool();
      }
      await _prepareReady();
      while (_ready.isNotEmpty) {
        final batch = _ready.sublist(0, min(_batchSize, _ready.length));
        _ready.removeRange(0, batch.length);
        await _deliverFresh(batch);
        await _prepareReady();
      }
    } while (_rerun || _raw.isNotEmpty);
  }

  // -------------------------------------------------------------------------------------------
  // Building events

  Future<void> _prepareReady() async {
    if (_raw.isEmpty) return;
    final pending = [..._raw];
    _raw.clear();
    for (final item in pending) {
      final envelope = await _prepare(item);
      if (envelope != null) _ready.add(envelope);
    }
  }

  Future<SignedEnvelope?> _prepare(_Pending pending) async {
    try {
      // A client belongs to one environment (its key, or its configuration). An event that says
      // otherwise is a bug, so drop it rather than relabel it or send it to be refused.
      final environment = pending.input['environment'];
      if (environment != null && environment != _environment!.wire) {
        _counters.droppedInvalid += 1;
        _report(SdkError(
          SdkErrorCode.invalidEvent,
          'event environment does not match the client',
          eventId: pending.id,
          details: ['environment: must be "${_environment!.wire}", the client\'s environment'],
        ));
        return null;
      }
      final event = _build(pending);
      _redact(event);
      final problems = validateEvent(event);
      if (problems.isNotEmpty) {
        _counters.droppedInvalid += 1;
        _report(SdkError(
          SdkErrorCode.invalidEvent,
          'event failed schema validation',
          eventId: pending.id,
          details: problems,
        ));
        return null;
      }
      return SignedEnvelope(event, await signEvent(event, _key));
    } catch (e) {
      _counters.droppedInvalid += 1;
      _report(SdkError(SdkErrorCode.invalidEvent, '$e', eventId: pending.id));
      return null;
    }
  }

  Map<String, Object?> _build(_Pending pending) {
    final input = pending.input;
    final ctx = pending.context;
    final instruction = _instruction(
      input.containsKey('instruction') ? input['instruction'] : ctx?.instruction?.toJson(),
    );
    final adapter = switch (input['source']) {
      {'adapter': final String adapter} => adapter,
      _ => 'custom',
    };
    return {
      'ape_version': '0.1',
      'id': pending.id,
      'type': input['type'],
      'occurred_at': input['occurred_at'] is String ? input['occurred_at'] : nowUtc(),
      'environment': _environment!.wire,
      // id and sdk always come from the client, so an input cannot sign as another source.
      'source': {'id': _key.kid, 'sdk': sdkName, 'adapter': adapter},
      'agent': input['agent'] ?? ctx?.agent?.toJson() ?? {'id': 'unattributed'},
      'owner': input['owner'] ?? ctx?.owner?.toJson() ?? {'id': 'unattributed', 'type': 'business'},
      'payment': input['payment'],
      'payee': input['payee'],
      if (instruction != null) 'instruction': instruction,
      for (final key in const ['instrument', 'evidence', 'related', 'labels'])
        if (input.containsKey(key)) key: input[key],
    };
  }

  /// An event's own instruction replaces the context's, as in the Node.js SDK. Only APE
  /// fields are kept, and `text` becomes `hash` here so it never leaves the device.
  static Map<String, Object?>? _instruction(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String) return null;
    final text = raw['text'];
    final hash =
        raw['hash'] is String ? raw['hash'] : (text is String ? hashInstruction(text) : null);
    if (hash == null) return null;
    return {
      'id': id,
      'hash': hash,
      for (final key in const ['summary', 'channel', 'issued_at', 'tool_call_id'])
        if (raw[key] is String) key: raw[key],
    };
  }

  void _redact(Map<String, Object?> event) {
    String clean(String s) => redactText(s, extraPatterns: _redactPatterns);

    final payment = event['payment'];
    if (payment is Map) {
      for (final key in const ['description', 'category', 'failure_reason']) {
        if (payment[key] case final String s) payment[key] = clean(s);
      }
    }
    for (final (parent, key) in const [
      ('agent', 'name'),
      ('owner', 'display_name'),
      ('payee', 'name'),
      ('payee', 'website'),
      ('payee', 'resource_url'),
      ('instruction', 'summary'),
    ]) {
      final obj = event[parent];
      if (obj is Map && obj[key] is String) obj[key] = clean(obj[key] as String);
    }
    // Keys as well as values. Identifiers (ids, rail refs) are left alone: numeric network ids
    // pass the Luhn check often enough that redacting them would corrupt real events.
    if (event['labels'] case final Map<Object?, Object?> labels) {
      event['labels'] = {
        for (final e in labels.entries)
          (e.key is String ? clean(e.key as String) : e.key):
              redactDeep(e.value, extraPatterns: _redactPatterns),
      };
    }
    final evidence = event['evidence'];
    if (evidence is List) {
      for (final item in evidence) {
        if (item is Map && item['format'] == 'json' && item['value'] != null) {
          final value = redactDeep(item['value'], extraPatterns: _redactPatterns)!;
          item['value'] = value;
          item['sha256'] = evidenceSha256(value);
        }
      }
    }
  }

  // -------------------------------------------------------------------------------------------
  // Delivery

  Future<void> _deliverFresh(List<SignedEnvelope> batch) async {
    final left = await _send(batch);
    if (left.isEmpty) {
      // The API is reachable again; give anything spooled earlier a go.
      if (_spool != null && DateTime.now().isAfter(_spoolCooldownUntil)) _replayRequested = true;
      return;
    }
    final spool = _spool;
    if (spool != null) {
      try {
        await spool.write(left);
        _counters.spooled += left.length;
        return;
      } catch (e) {
        _report(SdkError(SdkErrorCode.spool, 'spool write failed: $e'));
      }
    }
    _counters.dropped += left.length;
    _report(
        SdkError(SdkErrorCode.deliveryFailed, 'gave up on ${left.length} event(s) after retries'));
  }

  /// Sends [batch] with retries. Accepted, rejected and fatal events are settled here; returns
  /// the ones still undelivered once retries run out.
  Future<List<SignedEnvelope>> _send(List<SignedEnvelope> batch) async {
    final transport = _transport;
    if (batch.isEmpty || transport == null) return const [];
    for (var attempt = 0;; attempt++) {
      final outcome = await transport.send(batch);
      switch (outcome) {
        case DeliveryOk(perEvent: false):
          _counters.accepted += batch.length;
          return const [];
        case DeliveryOk(:final results):
          _applyResults(batch, results);
          return const [];
        case DeliveryTooLarge():
          if (batch.length == 1) {
            // Never spool it: it would be too large on every replay too.
            _counters.dropped += 1;
            _report(SdkError(
              SdkErrorCode.deliveryFailed,
              'event is too large to send',
              eventId: batch.single.id,
              serverCode: 'payload_too_large',
            ));
            return const [];
          }
          final mid = (batch.length + 1) ~/ 2;
          return [...await _send(batch.sublist(0, mid)), ...await _send(batch.sublist(mid))];
        case DeliveryFatal(:final status, :final message, :final serverCode, :final details):
          _counters.dropped += batch.length;
          _report(SdkError(
            status == 401 || status == 403
                ? SdkErrorCode.unauthorized
                : SdkErrorCode.deliveryFailed,
            message,
            serverCode: serverCode,
            details: details,
          ));
          return const [];
        case DeliveryRetry():
          if (attempt >= _retryDelays.length) return batch;
          _counters.retries += 1;
          await Future<void>.delayed(_jitter(_retryDelays[attempt]));
      }
    }
  }

  void _applyResults(List<SignedEnvelope> batch, List<IngestResult> results) {
    final byId = {for (final r in results) r.id: r};
    var missing = 0;
    for (final envelope in batch) {
      final result = byId[envelope.id];
      switch (result?.status) {
        case null:
          // Not retried: a backend that never passes results through would loop forever, and a
          // retry of a delivered event is only a duplicate anyway.
          missing += 1;
        case 'duplicate':
          _counters.duplicates += 1;
        case 'rejected':
          _counters.rejected += 1;
          _report(SdkError(
            SdkErrorCode.rejected,
            'server rejected event',
            eventId: envelope.id,
            serverCode: result?.serverCode,
          ));
        default:
          _counters.accepted += 1;
      }
    }
    if (missing == 0) return;
    _counters.unconfirmed += missing;
    if (_unconfirmedReported) return;
    _unconfirmedReported = true;
    // A `config` error, once: it almost always means the destination is set up wrong.
    _report(SdkError(
      SdkErrorCode.config,
      'the response had no result for $missing event(s); a forwarding backend must return '
      "HalvorAI's response unchanged",
    ));
  }

  /// Re-sends spooled batches, oldest first. An entry the API refuses for good is removed so it
  /// cannot block the ones behind it; only a retryable failure stops the replay.
  Future<void> _replaySpool() async {
    final spool = _spool;
    if (spool == null || _disabled || DateTime.now().isBefore(_spoolCooldownUntil)) return;
    final List<String> ids;
    try {
      ids = await spool.list();
    } catch (e) {
      _report(SdkError(SdkErrorCode.spool, 'spool list failed: $e'));
      return;
    }
    for (final id in ids) {
      try {
        final envelopes = await spool.read(id);
        final left = await _send(envelopes);
        _counters.replayed += envelopes.length - left.length;
        if (left.isEmpty) {
          await spool.remove(id);
          continue;
        }
        await spool.replace(id, left);
        final backoff = _retryDelays.isEmpty ? const Duration(seconds: 32) : _retryDelays.last;
        _spoolCooldownUntil = DateTime.now().add(backoff);
        return;
      } catch (e) {
        _report(SdkError(SdkErrorCode.spool, 'spool replay failed: $e'));
        return;
      }
    }
  }

  Duration _jitter(Duration base) =>
      Duration(microseconds: (base.inMicroseconds * (1 + _random.nextDouble() * 0.2)).floor());

  // -------------------------------------------------------------------------------------------
  // Errors

  void _disable(String message) {
    _disabled = true;
    _configMessage = message;
    _reportConfigOnce();
  }

  void _reportConfigOnce() {
    if (_configReported) return;
    _configReported = true;
    final message = _configMessage ?? 'client is disabled due to bad configuration';
    developer.log(message, name: 'halvorai_ingest', level: 900);
    _report(SdkError(SdkErrorCode.config, message));
  }

  void _report(SdkError error) {
    try {
      _onError?.call(error);
    } catch (_) {
      // onError must never break the client.
    }
  }
}

/// A deep copy of the JSON-shaped parts, so later changes by the caller do not leak in.
Object? _copy(Object? value) => switch (value) {
      Map() => <String, Object?>{for (final e in value.entries) '${e.key}': _copy(e.value)},
      List() => [for (final item in value) _copy(item)],
      _ => value,
    };
