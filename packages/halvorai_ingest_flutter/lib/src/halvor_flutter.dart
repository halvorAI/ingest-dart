import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'device_identity.dart';
import 'file_spool.dart';
import 'key_store.dart';
import 'provisioning.dart';

/// Waits between attempts to register the device, after which it keeps the last one.
const defaultRegistrationRetryDelays = [
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
];

/// Why a direct API key cannot be used here, or null if it can.
///
/// An app binary can be unpacked, so a key in it is public. Only `hk_test_` keys are allowed,
/// and only in debug builds; a shipped app must forward through your backend.
@visibleForTesting
String? apiKeyProblem(String apiKey, Environment environment, {required bool debugBuild}) {
  if (!debugBuild) {
    return 'debugApiKey cannot be used in a release or profile build: an app binary is public. '
        'Use provisionUrl and forwardUrl, so the key stays on your backend.';
  }
  if (apiKeyEnvironment(apiKey) != 'test') {
    return 'debugApiKey must be an hk_test_ key; live keys never belong in an app.';
  }
  if (environment != Environment.test) return 'debugApiKey needs environment: Environment.test.';
  return null;
}

/// Records each payment an agent in this app makes, signed with this install's own key.
///
/// ```dart
/// final halvor = await HalvorFlutter.start(
///   environment: Environment.live,
///   provisionUrl: Uri.parse('https://api.example.com/halvor/sources'),
///   forwardUrl: Uri.parse('https://api.example.com/halvor/events'),
///   headers: () async => {'authorization': 'Bearer ${await session.token()}'},
/// );
/// halvor.emit(EventInput.settled(...));
/// ```
///
/// On first start the SDK makes a key in secure storage and registers its public half through
/// your backend ([provisionUrl]). Events go to your backend ([forwardUrl]), which checks the
/// user and passes them to HalvorAI unchanged. The app never holds an API key.
///
/// Events emitted before registration finishes wait in memory, with the context they were
/// emitted in. Delivery is batched; undelivered batches are kept on disk and retried, and the
/// queue is flushed when the app goes to the background. Like the core client, nothing here
/// throws: problems are reported through `onError`.
class HalvorFlutter with WidgetsBindingObserver {
  HalvorFlutter._({
    required Environment environment,
    required DeviceIdentity? identity,
    required Uri? provisionUrl,
    required Uri? forwardUrl,
    required HeadersCallback? headers,
    required String? apiKey,
    required String? endpoint,
    required String deviceName,
    required Directory dataDirectory,
    required http.Client http,
    required bool ownsHttp,
    required ErrorHandler? onError,
    required List<ExtraPattern> redactPatterns,
    required int batchSize,
    required Duration flushInterval,
    required List<Duration> retryDelays,
    required List<Duration> registrationRetryDelays,
    required int maxPendingEvents,
  })  : _environment = environment,
        _identity = identity,
        _provisionUrl = provisionUrl,
        _forwardUrl = forwardUrl,
        _headers = headers,
        _apiKey = apiKey,
        _endpoint = endpoint,
        _deviceName = deviceName,
        _dataDirectory = dataDirectory,
        _http = http,
        _ownsHttp = ownsHttp,
        _onError = onError,
        _redactPatterns = redactPatterns,
        _batchSize = batchSize,
        _flushInterval = flushInterval,
        _retryDelays = retryDelays,
        _registrationRetryDelays = registrationRetryDelays,
        _maxPendingEvents = maxPendingEvents;

  /// Opens this install's identity and starts delivery. Returns at once if the device is
  /// already registered; otherwise registration runs in the background.
  ///
  /// Give either [provisionUrl] and [forwardUrl] (shipped apps), or [debugApiKey] to talk to
  /// HalvorAI directly from a debug build with an `hk_test_` key.
  static Future<HalvorFlutter> start({
    required Environment environment,
    Uri? provisionUrl,
    Uri? forwardUrl,
    HeadersCallback? headers,
    String? debugApiKey,
    String? debugEndpoint,
    String deviceName = 'halvorai_ingest_flutter',
    ErrorHandler? onError,
    List<ExtraPattern> redactPatterns = const [],
    int batchSize = 100,
    Duration flushInterval = const Duration(seconds: 5),
    List<Duration> retryDelays = defaultRetryDelays,
    List<Duration> registrationRetryDelays = defaultRegistrationRetryDelays,
    int maxPendingEvents = 1000,
    bool observeLifecycle = true,
    @visibleForTesting KeyStore? keyStore,
    @visibleForTesting Directory? dataDirectory,
    @visibleForTesting http.Client? httpClient,
    @visibleForTesting bool? debugBuild,
  }) async {
    final forwarding = provisionUrl != null || forwardUrl != null;
    String? problem;
    if (forwarding && debugApiKey != null) {
      problem = 'pass either provisionUrl and forwardUrl, or debugApiKey, not both';
    } else if (forwarding && (provisionUrl == null || forwardUrl == null)) {
      problem = 'provisionUrl and forwardUrl go together';
    } else if (!forwarding && debugApiKey == null) {
      problem = 'no destination: pass provisionUrl and forwardUrl';
    } else if (debugApiKey != null) {
      problem = apiKeyProblem(debugApiKey, environment, debugBuild: debugBuild ?? kDebugMode);
    }

    Directory? directory = dataDirectory;
    DeviceIdentity? identity;
    if (problem == null) {
      try {
        directory ??= Directory(
            '${(await getApplicationSupportDirectory()).path}/halvorai/${environment.wire}');
        identity = await DeviceIdentity.open(
          store: keyStore ?? SecureKeyStore(),
          dataDirectory: directory,
          environment: environment,
        );
      } catch (e) {
        problem = 'could not open secure storage: $e';
      }
    }

    final halvor = HalvorFlutter._(
      environment: environment,
      identity: problem == null ? identity : null,
      provisionUrl: provisionUrl,
      forwardUrl: forwardUrl,
      headers: headers,
      apiKey: debugApiKey,
      endpoint: debugEndpoint,
      deviceName: deviceName,
      dataDirectory: directory ?? Directory.systemTemp,
      http: httpClient ?? http.Client(),
      ownsHttp: httpClient == null,
      onError: onError,
      redactPatterns: redactPatterns,
      batchSize: batchSize,
      flushInterval: flushInterval,
      retryDelays: retryDelays,
      registrationRetryDelays: registrationRetryDelays,
      maxPendingEvents: maxPendingEvents,
    );
    if (problem != null) {
      halvor._disable(problem);
      return halvor;
    }
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(halvor);
      halvor._observing = true;
    }
    final registered = await _guard(halvor, () => identity!.registered());
    if (registered != null) {
      halvor._ready(registered);
    } else {
      unawaited(halvor._register());
    }
    return halvor;
  }

  final Environment _environment;
  final DeviceIdentity? _identity;
  final Uri? _provisionUrl;
  final Uri? _forwardUrl;
  final HeadersCallback? _headers;
  final String? _apiKey;
  final String? _endpoint;
  final String _deviceName;
  final Directory _dataDirectory;
  final http.Client _http;
  final bool _ownsHttp;
  final ErrorHandler? _onError;
  final List<ExtraPattern> _redactPatterns;
  final int _batchSize;
  final Duration _flushInterval;
  final List<Duration> _retryDelays;
  final List<Duration> _registrationRetryDelays;
  final int _maxPendingEvents;

  HalvorClient? _client;
  final _pending = <(Map<String, Object?>, AgentContext?)>[];
  var _pendingDropped = 0;
  var _pendingDropReported = false;
  bool _disabled = false;
  bool _closed = false;
  bool _observing = false;
  bool _registering = false;
  int _registrationAttempt = 0;
  Timer? _registrationTimer;

  /// True once the device is registered and events are being delivered.
  bool get isReady => _client != null;

  /// False when the configuration was rejected; events are then dropped and counted.
  bool get enabled => !_disabled;

  /// The registered `src_` id, or null before registration.
  String? get sourceId => _sourceId;
  String? _sourceId;

  /// Events waiting for registration to finish.
  int get pendingEvents => _pending.length;

  /// The core client's counters, once registered. Before that, only [pendingEvents] moves.
  ClientStats stats() => _client?.stats() ?? ClientStats(queued: _pending.length);

  /// Queues [event] and returns its id. Never throws.
  String emit(EventInput event) {
    try {
      return emitJson(event.toJson());
    } catch (e) {
      final id = event.id ?? newEventId();
      _report(SdkError(SdkErrorCode.invalidEvent, 'emit failed: $e', eventId: id));
      return id;
    }
  }

  /// Queues a partial event given as JSON and returns its id. Never throws.
  String emitJson(Map<String, Object?> event) {
    final client = _client;
    if (client != null) return client.emitJson(event);
    final given = event['id'];
    final id = given is String ? given : newEventId();
    if (_disabled || _closed) return id;
    // Stamp the id and time now, so the event keeps them when it is sent after registration.
    _pending.add((
      {...event, 'id': id, 'occurred_at': event['occurred_at'] ?? formatUtc(DateTime.now())},
      currentContext(),
    ));
    if (_pending.length > _maxPendingEvents) {
      _pending.removeAt(0);
      _pendingDropped += 1;
      if (!_pendingDropReported) {
        _pendingDropReported = true;
        _report(SdkError(
          SdkErrorCode.deliveryFailed,
          'dropping the oldest events: more than $_maxPendingEvents are waiting for the device '
          'to be registered',
        ));
      }
    }
    return id;
  }

  /// Events dropped because too many were waiting for registration.
  int get droppedBeforeRegistration => _pendingDropped;

  /// Sends what is queued. See [HalvorClient.flush]; before registration this returns false.
  Future<bool> flush({Duration? timeout, bool replaySpool = true}) async {
    final client = _client;
    if (client == null) return _pending.isEmpty;
    return client.flush(timeout: timeout, replaySpool: replaySpool);
  }

  /// Stops lifecycle handling and sends what is queued. Spooled batches stay for next start.
  Future<bool> close({Duration? timeout}) async {
    _closed = true;
    _stopObserving();
    _registrationTimer?.cancel();
    final drained = await _client?.close(timeout: timeout) ?? _pending.isEmpty;
    if (_ownsHttp) _http.close();
    return drained;
  }

  /// Forgets this install's key and queued events, for example when the user deletes their
  /// account. This instance stops; the next [start] registers a new key.
  Future<void> resetIdentity() async {
    await close(timeout: Duration.zero);
    _pending.clear();
    await _identity?.reset();
    final spool = Directory('${_dataDirectory.path}/spool');
    if (await spool.exists()) await spool.delete(recursive: true);
  }

  // -------------------------------------------------------------------------------------------
  // App lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        // The OS gives a backgrounded app a few seconds; spooled batches can wait.
        unawaited(flush(timeout: const Duration(seconds: 3), replaySpool: false));
      case AppLifecycleState.resumed:
        // Coming back often means the network is back too.
        if (_client == null) {
          _registrationTimer?.cancel();
          unawaited(_register());
        } else {
          unawaited(flush(timeout: const Duration(seconds: 10)));
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _stopObserving() {
    if (!_observing) return;
    WidgetsBinding.instance.removeObserver(this);
    _observing = false;
  }

  // -------------------------------------------------------------------------------------------
  // Registration

  Future<void> _register() async {
    final identity = _identity;
    if (identity == null || _registering || _client != null || _closed) return;
    _registering = true;
    try {
      final key = await identity.pending();
      final sourceId = await registerKey(
        client: _http,
        url: _apiKey != null
            ? Uri.parse(
                '${(_endpoint ?? sandboxEndpoint).replaceFirst(RegExp(r'/+$'), '')}/v1/sources')
            : _provisionUrl!,
        key: key,
        name: _deviceName,
        headers: _headers,
        apiKey: _apiKey,
      );
      if (_closed) return;
      _ready(await identity.markRegistered(sourceId));
    } catch (e) {
      _report(SdkError(
        e is ProvisioningException && (e.status == 400 || e.status == 422)
            ? SdkErrorCode.config
            : SdkErrorCode.deliveryFailed,
        e is ProvisioningException ? e.message : 'registration failed: $e',
        serverCode: e is ProvisioningException && e.status != null ? '${e.status}' : null,
      ));
      _scheduleRegistration();
    } finally {
      _registering = false;
    }
  }

  void _scheduleRegistration() {
    if (_closed || _registrationRetryDelays.isEmpty) return;
    final delay =
        _registrationRetryDelays[min(_registrationAttempt, _registrationRetryDelays.length - 1)];
    _registrationAttempt += 1;
    _registrationTimer?.cancel();
    _registrationTimer = Timer(delay, () => unawaited(_register()));
  }

  void _ready(SourceKey key) {
    _sourceId = key.kid;
    late final HalvorClient client;
    final spool = FileSpool(
      Directory('${_dataDirectory.path}/spool'),
      onEvict: (count, reason) => client.notify(
        SdkError(SdkErrorCode.spool, 'deleted $count spooled event(s): $reason'),
      ),
    );
    client = HalvorClient(
      sourceKey: key,
      environment: _environment,
      transport: _apiKey != null
          ? HalvorApiTransport(apiKey: _apiKey, endpoint: _endpoint, httpClient: _http)
          : ForwardingTransport(_forwardUrl!, headers: _headers, httpClient: _http),
      spool: spool,
      onError: _onError,
      redactPatterns: _redactPatterns,
      batchSize: _batchSize,
      flushInterval: _flushInterval,
      retryDelays: _retryDelays,
    );
    _client = client;
    // Send what waited, each in the context it was emitted in.
    final waiting = [..._pending];
    _pending.clear();
    for (final (event, context) in waiting) {
      if (context == null) {
        client.emitJson(event);
      } else {
        withAgentContext(context, () => client.emitJson(event));
      }
    }
  }

  // -------------------------------------------------------------------------------------------
  // Errors

  void _disable(String message) {
    _disabled = true;
    developer.log(message, name: 'halvorai_ingest_flutter', level: 900);
    _report(SdkError(SdkErrorCode.config, message));
  }

  void _report(SdkError error) {
    try {
      _onError?.call(error);
    } catch (_) {
      // onError must never break the SDK.
    }
  }

  static Future<T?> _guard<T>(HalvorFlutter halvor, Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      halvor._report(SdkError(SdkErrorCode.config, 'could not read the device key: $e'));
      return null;
    }
  }
}
