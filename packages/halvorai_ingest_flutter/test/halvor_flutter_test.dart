import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _context = AgentContext(
  agent: AgentRef(id: 'agt_travel_12'),
  owner: OwnerRef(id: 'own_u_4410', type: OwnerType.person),
);

EventInput _settled() => const EventInput.settled(
      payment: Payment(
        paymentId: 'pi_1',
        amount: Amount.minor('41200', 'USD'),
        ref: StripeRef(paymentIntent: 'pi_1'),
      ),
      payee: Payee.merchant(name: 'Example Airways'),
    );

final _provisionUrl = Uri.parse('https://app.example/halvor/sources');
final _forwardUrl = Uri.parse('https://app.example/halvor/events');
final _testKey = 'hk_test_${'a' * 32}';

/// A customer backend (and, for debug mode, HalvorAI) that records what it receives.
class FakeBackend {
  final registrations = <http.Request>[];
  final deliveries = <http.Request>[];
  var registrationFailures = 0;
  var deliveryDown = false;
  var registrationDelay = Duration.zero;
  var _sources = 0;

  late final client = MockClient((request) async {
    switch (request.url.path) {
      case '/halvor/sources' || '/v1/sources':
        registrations.add(request);
        await Future<void>.delayed(registrationDelay);
        if (registrationFailures > 0) {
          registrationFailures--;
          return http.Response('down', 503);
        }
        final id = 'src_device_${++_sources}';
        return request.url.path == '/v1/sources'
            ? http.Response(jsonEncode({'id': id}), 201)
            : http.Response(jsonEncode({'source_id': id}), 200);
      case '/halvor/events' || '/v1/events':
        deliveries.add(request);
        if (deliveryDown) return http.Response('down', 503);
        delivered.addAll(_envelopes(request));
        return http.Response(
          jsonEncode({
            'results': [
              for (final e in _envelopes(request)) {'id': e.id, 'status': 'accepted'},
            ],
          }),
          200,
        );
      default:
        return http.Response('not found', 404);
    }
  });

  static List<SignedEnvelope> _envelopes(http.Request r) => [
        for (final e in (jsonDecode(r.body) as Map)['events'] as List)
          SignedEnvelope.fromJson((e as Map).cast<String, Object?>()),
      ];

  /// Envelopes the backend accepted; failed attempts are only in [deliveries].
  final delivered = <SignedEnvelope>[];

  Map<String, Object?> registeredJwk([int i = 0]) =>
      ((jsonDecode(registrations[i].body) as Map)['public_jwk'] as Map).cast<String, Object?>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late MemoryKeyStore store;
  late FakeBackend backend;
  late List<SdkError> errors;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('halvor_flutter_');
    store = MemoryKeyStore();
    backend = FakeBackend();
    errors = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<HalvorFlutter> start({
    Directory? dataDirectory,
    List<Duration> registrationRetryDelays = const [Duration(milliseconds: 10)],
    int maxPendingEvents = 1000,
    Duration flushInterval = const Duration(hours: 1),
    List<Duration> retryDelays = const [Duration.zero],
  }) =>
      HalvorFlutter.start(
        environment: Environment.live,
        provisionUrl: _provisionUrl,
        forwardUrl: _forwardUrl,
        headers: () => {'authorization': 'Bearer session_1'},
        deviceName: 'test-device',
        onError: errors.add,
        retryDelays: retryDelays,
        registrationRetryDelays: registrationRetryDelays,
        maxPendingEvents: maxPendingEvents,
        flushInterval: flushInterval,
        observeLifecycle: false,
        keyStore: store,
        dataDirectory: dataDirectory ?? dir,
        httpClient: backend.client,
      );

  Future<void> untilReady(HalvorFlutter halvor) async {
    for (var i = 0; i < 200 && !halvor.isReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(halvor.isReady, isTrue, reason: 'registration did not finish: $errors');
  }

  group('registration', () {
    test('registers the public key through the backend, per the provisioning contract', () async {
      final halvor = await start();
      await untilReady(halvor);

      final request = backend.registrations.single;
      expect(request.url, _provisionUrl);
      expect(request.headers['authorization'], 'Bearer session_1');
      final body = jsonDecode(request.body) as Map;
      expect(body.keys, unorderedEquals(['public_jwk', 'name']));
      expect(body['name'], 'test-device');
      expect(backend.registeredJwk().keys, unorderedEquals(['kty', 'crv', 'x']),
          reason: 'never d, and no placeholder kid');
      expect(halvor.sourceId, 'src_device_1');
      await halvor.close();
    });

    test('events emitted before registration are sent after it, unchanged and in context',
        () async {
      backend.registrationFailures = 1;
      final halvor = await start();
      final id = withAgentContext(_context, () => halvor.emit(_settled()));
      expect(halvor.pendingEvents, 1);

      await untilReady(halvor);
      await halvor.flush();

      final envelope = backend.delivered.single;
      expect(envelope.event['id'], id);
      expect((envelope.event['agent'] as Map)['id'], 'agt_travel_12');
      expect((envelope.event['source'] as Map)['id'], 'src_device_1');
      expect(envelope.event['environment'], 'live');
      expect(await verifyEvent(envelope.event, envelope.sig, backend.registeredJwk(1)), isTrue);
      expect(errors.single.code, SdkErrorCode.deliveryFailed, reason: 'the first attempt failed');
      await halvor.close();
    });

    test('a restart reuses the registered key without registering again', () async {
      final first = await start();
      await untilReady(first);
      await first.close();

      final second = await start();
      expect(second.isReady, isTrue);
      expect(second.sourceId, 'src_device_1');
      expect(backend.registrations, hasLength(1));
      await second.close();
    });

    test('a key left in the Keychain by a previous install is replaced', () async {
      final first = await start();
      await untilReady(first);
      await first.close();

      // A reinstall: secure storage survived, the app's data directory did not.
      final newDir = Directory.systemTemp.createTempSync('halvor_reinstall_');
      addTearDown(() => newDir.deleteSync(recursive: true));
      final second = await start(dataDirectory: newDir);
      await untilReady(second);

      expect(backend.registrations, hasLength(2));
      expect(backend.registeredJwk(1)['x'], isNot(backend.registeredJwk(0)['x']));
      await second.close();
    });

    test('caps the events waiting for registration and reports it once', () async {
      backend.registrationFailures = 1000;
      final halvor =
          await start(registrationRetryDelays: const [Duration(hours: 1)], maxPendingEvents: 2);
      for (var i = 0; i < 4; i++) {
        halvor.emit(_settled());
      }
      expect(halvor.pendingEvents, 2);
      expect(halvor.droppedBeforeRegistration, 2);
      expect(errors.where((e) => e.message.contains('waiting for the device')), hasLength(1));
      await halvor.close();
    });

    test('resetIdentity forgets the key, so the next start registers a new one', () async {
      final first = await start();
      await untilReady(first);
      await first.resetIdentity();

      final second = await start();
      await untilReady(second);
      expect(backend.registrations, hasLength(2));
      expect(second.sourceId, 'src_device_2');
      await second.close();
    });
  });

  group('delivery', () {
    test('forwards signed envelopes to the backend with the app headers', () async {
      final halvor = await start();
      await untilReady(halvor);
      halvor.emit(_settled());
      await halvor.flush();

      final request = backend.deliveries.single;
      expect(request.url, _forwardUrl);
      expect(request.headers['authorization'], 'Bearer session_1');
      expect(halvor.stats().accepted, 1);
      await halvor.close();
    });

    test('keeps undelivered batches on disk and sends them after a restart', () async {
      final first = await start();
      await untilReady(first);
      backend.deliveryDown = true;
      first.emit(_settled());
      await first.flush(replaySpool: false);
      expect(first.stats().spooled, 1);
      await first.close();

      backend.deliveryDown = false;
      final second = await start();
      await second.flush();
      expect(backend.delivered, hasLength(1));
      expect(second.stats().replayed, 1);
      await second.close();
    });

    test('going to the background sends the queue without waiting for the interval', () async {
      final halvor = await start();
      await untilReady(halvor);
      halvor.emit(_settled());

      halvor.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.delivered, hasLength(1));
      await halvor.close();
    });

    test('coming back to the foreground retries registration at once', () async {
      backend.registrationFailures = 1;
      final halvor = await start(registrationRetryDelays: const [Duration(hours: 1)]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(halvor.isReady, isFalse);

      halvor.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await untilReady(halvor);
      await halvor.close();
    });
  });

  group('API keys in the app', () {
    Future<HalvorFlutter> direct(String key, {required bool debugBuild, Environment? env}) =>
        HalvorFlutter.start(
          environment: env ?? Environment.test,
          debugApiKey: key,
          debugEndpoint: 'http://localhost:8787',
          onError: errors.add,
          observeLifecycle: false,
          keyStore: store,
          dataDirectory: dir,
          httpClient: backend.client,
          debugBuild: debugBuild,
        );

    test('a release build refuses any API key', () async {
      final halvor = await direct(_testKey, debugBuild: false);
      expect(halvor.enabled, isFalse);
      expect(errors.single.code, SdkErrorCode.config);
      expect(errors.single.message, contains('release'));
      expect(halvor.emit(_settled()), startsWith('evt_'), reason: 'still never throws');
      expect(backend.registrations, isEmpty);
    });

    test('a live key is refused even in a debug build', () async {
      final halvor = await direct('hk_live_${'a' * 32}', debugBuild: true, env: Environment.live);
      expect(halvor.enabled, isFalse);
      expect(errors.single.message, contains('hk_test_'));
    });

    test('a debug build with a test key registers and sends straight to HalvorAI', () async {
      final halvor = await direct(_testKey, debugBuild: true);
      await untilReady(halvor);
      halvor.emit(_settled());
      await halvor.flush();

      final registration = backend.registrations.single;
      expect(registration.url.toString(), 'http://localhost:8787/v1/sources');
      expect(registration.headers['authorization'], 'Bearer $_testKey');
      expect((jsonDecode(registration.body) as Map)['adapter'], 'custom');
      expect(backend.deliveries.single.url.toString(), 'http://localhost:8787/v1/events');
      await halvor.close();
    });
  });

  group('core review fixes', () {
    test('resetIdentity during a retry wait leaves nothing on disk', () async {
      // A short retry wait, so a delivery that outlives the reset would write within the test.
      final halvor = await start(retryDelays: const [Duration(milliseconds: 200)]);
      await untilReady(halvor);
      backend.deliveryDown = true;
      halvor.emit(_settled());
      unawaited(halvor.flush());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await halvor.resetIdentity().timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(Directory('${dir.path}/spool').existsSync(), isFalse);
      expect(store.values, isEmpty);
    });

    test('resetIdentity during a registration leaves no key behind', () async {
      backend.registrationDelay = const Duration(milliseconds: 200);
      final halvor = await start();
      await halvor.resetIdentity().timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(store.values, isEmpty);
    });

    test('events waiting for registration keep exactly their own context', () async {
      backend.registrationFailures = 1;
      const ambient = AgentContext(
        agent: AgentRef(id: 'agt_wrong'),
        owner: OwnerRef(id: 'own_wrong', type: OwnerType.business),
      );
      // Registration starts, and its retry timer runs, inside a zone with another context.
      final halvor = await withAgentContext(ambient, () => start());
      final bare = halvor.emit(_settled());
      final partial = withAgentContext(
        const AgentContext(agent: AgentRef(id: 'agt_mine')),
        () => halvor.emit(_settled()),
      );
      await untilReady(halvor);
      await halvor.flush();

      final byId = {for (final e in backend.delivered) e.id: e.event};
      expect(byId[bare]!['agent'], {'id': 'unattributed'});
      expect((byId[partial]!['agent'] as Map)['id'], 'agt_mine');
      expect((byId[partial]!['owner'] as Map)['id'], 'unattributed');
      await halvor.close();
    });

    test('closing while registration is in flight still keeps the registered key', () async {
      backend.registrationDelay = const Duration(milliseconds: 100);
      final first = await start();
      await first.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      backend.registrationDelay = Duration.zero;
      final second = await start();
      expect(second.isReady, isTrue);
      expect(backend.registrations, hasLength(1), reason: 'not registered a second time');
      await second.close();
    });

    test('a debug endpoint given as a full /v1/events URL registers at /v1/sources', () async {
      final halvor = await HalvorFlutter.start(
        environment: Environment.test,
        debugApiKey: _testKey,
        debugEndpoint: 'http://localhost:8787/v1/events',
        observeLifecycle: false,
        keyStore: store,
        dataDirectory: dir,
        httpClient: backend.client,
        debugBuild: true,
      );
      await untilReady(halvor);
      expect(backend.registrations.single.url.toString(), 'http://localhost:8787/v1/sources');
      await halvor.close();
    });

    test('URLs that carry the session headers must be https', () async {
      final halvor = await HalvorFlutter.start(
        environment: Environment.live,
        provisionUrl: Uri.parse('http://app.example/halvor/sources'),
        forwardUrl: _forwardUrl,
        onError: errors.add,
        observeLifecycle: false,
        keyStore: store,
        dataDirectory: dir,
        httpClient: backend.client,
      );
      expect(halvor.enabled, isFalse);
      expect(errors.single.message, contains('https'));
      expect(backend.registrations, isEmpty);
    });
  });

  group('configuration', () {
    test('needs a destination, and only one kind', () async {
      final none = await HalvorFlutter.start(
          environment: Environment.live, onError: errors.add, observeLifecycle: false);
      expect(none.enabled, isFalse);

      final half = await HalvorFlutter.start(
        environment: Environment.live,
        provisionUrl: _provisionUrl,
        onError: errors.add,
        observeLifecycle: false,
      );
      expect(half.enabled, isFalse);
      expect(errors.map((e) => e.code), everyElement(SdkErrorCode.config));
    });
  });

  testWidgets('listens to the app lifecycle once started, and stops on close', (tester) async {
    await tester.runAsync(() async {
      final halvor = await HalvorFlutter.start(
        environment: Environment.live,
        provisionUrl: _provisionUrl,
        forwardUrl: _forwardUrl,
        keyStore: store,
        dataDirectory: dir,
        httpClient: backend.client,
        flushInterval: const Duration(hours: 1),
      );
      await untilReady(halvor);
      halvor.emit(_settled());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.delivered, hasLength(1));

      await halvor.close();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });
}
