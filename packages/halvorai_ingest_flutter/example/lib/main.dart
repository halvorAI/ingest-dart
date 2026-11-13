// HalvorAI Flutter example: an agent in this app pays, and each payment is recorded as an event
// signed with a key that lives only on this device.
//
// Start the demo backend first (example/backend: `npm install && npm start`). On an Android
// emulator, also run `adb reverse tcp:8787 tcp:8787` so the app reaches it at localhost.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Flutter 3.50 deprecates this import, but its replacement isn't in 3.27, the oldest Flutter
// this package supports.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:halvorai_ingest/x402.dart';
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';
import 'package:http/http.dart' as http;

/// The demo backend. Override with `--dart-define=BACKEND=http://localhost:9000`.
const backend = String.fromEnvironment('BACKEND', defaultValue: 'http://localhost:8787');

/// The signed-in user of this demo app, sent to the backend as the session.
const userId = 'own_demo_user';

/// Who every payment is attributed to: the agent, the user it acts for and what it was asked.
const agentContext = AgentContext(
  agent: AgentRef(id: 'agt_demo', name: 'Demo shopping agent', framework: 'flutter-example'),
  owner: OwnerRef(id: userId, type: OwnerType.person, country: 'US'),
  instruction: InstructionRef(id: 'task_demo', text: r'Buy market data, under $1 a day'),
);

Future<HalvorFlutter> startHalvor(void Function(SdkError) onError) => HalvorFlutter.start(
      environment: Environment.test,
      provisionUrl: Uri.parse('$backend/halvor/sources'),
      forwardUrl: Uri.parse('$backend/halvor/events'),
      headers: () => {'authorization': 'Bearer $userId'},
      deviceName: 'flutter example (${Platform.operatingSystem})',
      onError: onError,
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = ValueNotifier<List<String>>([]);
  void onError(SdkError e) => errors.value = [...errors.value, '${e.code.wire}: ${e.message}'];
  runApp(ExampleApp(halvor: await startHalvor(onError), errors: errors, onError: onError));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.halvor, required this.errors, required this.onError});

  final HalvorFlutter halvor;
  final ValueNotifier<List<String>> errors;
  final void Function(SdkError) onError;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HalvorAI example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: HomePage(halvor: halvor, errors: errors, onError: onError),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.halvor, required this.errors, required this.onError});

  final HalvorFlutter halvor;
  final ValueNotifier<List<String>> errors;
  final void Function(SdkError) onError;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late HalvorFlutter halvor = widget.halvor;
  late final Timer _refresh;
  final _random = Random.secure();
  final _activity = <String>[];
  var _payments = 0;
  var _offline = false;
  var _backendEvents = '…';

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final res = await http.get(Uri.parse('$backend/admin/events'));
      final body = jsonDecode(res.body) as Map<String, Object?>;
      final events = (body['events']! as List).cast<Map<String, Object?>>();
      final verified = events.where((e) => e['verified'] == true).length;
      _backendEvents = '${events.length} received, $verified signature-verified';
    } catch (_) {
      _backendEvents = 'backend not reachable';
    }
    if (mounted) setState(() {});
  }

  void _note(String line) => setState(() => _activity.insert(0, line));

  /// A card payment the agent made: one `payment.settled` event.
  void _pay() {
    final n = ++_payments;
    final id = withAgentContext(
      agentContext,
      () => halvor.emit(EventInput.settled(
        payment: Payment(
          paymentId: 'pi_demo_$n',
          amount: const Amount.minor('1299', 'USD'),
          ref: StripeRef(paymentIntent: 'pi_demo_$n'),
          description: 'Market data subscription',
        ),
        payee: const Payee.merchant(name: 'Example Data Co'),
      )),
    );
    _note('emitted payment $n ($id)');
  }

  /// An x402 purchase through HalvorX402Client: challenge, signed payment and settlement.
  Future<void> _payX402() async {
    final client = HalvorX402Client(halvor);
    try {
      final response = await withAgentContext(
        agentContext,
        () => _payWithX402(client, Uri.parse('$backend/premium-data')),
      );
      _note('x402 -> ${response.statusCode} ${response.body}');
    } catch (e) {
      _note('x402 failed: $e');
    } finally {
      client.close();
    }
  }

  /// Stands in for a real x402 paying client: try, read the 402, sign, retry. The signature is
  /// random; the demo backend does not check it, as a real facilitator would.
  Future<http.Response> _payWithX402(http.Client client, Uri url) async {
    final first = await client.get(url);
    final requiredHeader = first.headers['payment-required'];
    if (first.statusCode != 402 || requiredHeader == null) return first;
    final required = decodePaymentHeader(requiredHeader);
    final accepted = ((required['accepts']! as List).first as Map).cast<String, Object?>();
    String hex(int bytes) =>
        List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = {
      'x402Version': 2,
      'resource': required['resource'],
      'accepted': accepted,
      'payload': {
        'signature': '0x${hex(65)}',
        'authorization': {
          'from': '0x857b06519E91e3A54538791bDbb0E22373e36b66',
          'to': accepted['payTo'],
          'value': accepted['amount'],
          'validAfter': '${now - 60}',
          'validBefore': '${now + 60}',
          'nonce': '0x${hex(32)}',
        },
      },
    };
    return client.get(url, headers: {'PAYMENT-SIGNATURE': encodePaymentHeader(payload)});
  }

  Future<void> _flush() async {
    final drained = await halvor.flush(timeout: const Duration(seconds: 10));
    _note('flush: ${drained ? 'everything sent' : 'still sending (see stats)'}');
  }

  Future<void> _toggleOffline() async {
    final next = !_offline;
    await http.post(Uri.parse('$backend/admin/offline'), body: jsonEncode({'offline': next}));
    setState(() => _offline = next);
    _note('backend event delivery ${next ? 'offline' : 'online'}');
  }

  Future<void> _resetIdentity() async {
    await halvor.resetIdentity();
    final fresh = await startHalvor(widget.onError);
    setState(() => halvor = fresh);
    _note('identity reset; registering a new key');
  }

  @override
  Widget build(BuildContext context) {
    final stats = halvor.stats();
    final status = [
      ('Device', halvor.isReady ? 'registered as ${halvor.sourceId}' : 'registering…'),
      ('Waiting to register', '${halvor.pendingEvents}'),
      ('Queued', '${stats.queued}'),
      ('Accepted', '${stats.accepted} (duplicates ${stats.duplicates})'),
      ('Spooled / replayed', '${stats.spooled} / ${stats.replayed}'),
      ('Dropped', '${stats.dropped + stats.droppedInvalid}'),
      ('Backend', _backendEvents),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('HalvorAI example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                key: const ValueKey('status'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (label, value) in status)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('$label: $value', key: ValueKey('status:$label')),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                  key: const ValueKey('pay'), onPressed: _pay, child: const Text('Pay \$12.99')),
              FilledButton.tonal(
                  key: const ValueKey('x402'),
                  onPressed: _payX402,
                  child: const Text('Pay with x402')),
              OutlinedButton(
                  key: const ValueKey('flush'), onPressed: _flush, child: const Text('Flush')),
              OutlinedButton(
                key: const ValueKey('offline'),
                onPressed: _toggleOffline,
                child: Text(_offline ? 'Backend: offline' : 'Backend: online'),
              ),
              TextButton(
                  key: const ValueKey('reset'),
                  onPressed: _resetIdentity,
                  child: const Text('Reset identity')),
            ],
          ),
          const SizedBox(height: 16),
          Text('Activity', style: Theme.of(context).textTheme.titleMedium),
          for (final line in _activity.take(8)) Text(line, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          Text('Errors reported by the SDK', style: Theme.of(context).textTheme.titleMedium),
          ValueListenableBuilder(
            valueListenable: widget.errors,
            builder: (context, errors, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (errors.isEmpty) const Text('none', style: TextStyle(fontSize: 12)),
                for (final e in errors.reversed.take(8))
                  Text(e, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
