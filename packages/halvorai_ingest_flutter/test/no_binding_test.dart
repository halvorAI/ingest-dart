import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halvorai_ingest_flutter/halvorai_ingest_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Deliberately no TestWidgetsFlutterBinding.ensureInitialized(): this file checks that start()
// works when the app calls it before the Flutter binding exists.
void main() {
  test('start() initializes the binding itself and still delivers', () async {
    final dir = Directory.systemTemp.createTempSync('halvor_no_binding_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final errors = <SdkError>[];
    final delivered = <Object?>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/sources')) {
        return http.Response(jsonEncode({'source_id': 'src_device_1'}), 200);
      }
      final events = (jsonDecode(request.body) as Map)['events'] as List;
      delivered.addAll(events);
      return http.Response(
        jsonEncode({
          'results': [
            for (final e in events)
              {'id': ((e as Map)['event'] as Map)['id'], 'status': 'accepted'},
          ],
        }),
        200,
      );
    });

    final halvor = await HalvorFlutter.start(
      environment: Environment.live,
      provisionUrl: Uri.parse('https://app.example/halvor/sources'),
      forwardUrl: Uri.parse('https://app.example/halvor/events'),
      onError: errors.add,
      keyStore: MemoryKeyStore(),
      dataDirectory: dir,
      httpClient: client,
    );
    for (var i = 0; i < 100 && !halvor.isReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(halvor.enabled, isTrue, reason: '$errors');
    expect(halvor.isReady, isTrue, reason: '$errors');
    halvor.emit(const EventInput.settled(
      payment: Payment(
        paymentId: 'pi_1',
        amount: Amount.minor('100', 'USD'),
        ref: StripeRef(paymentIntent: 'pi_1'),
      ),
      payee: Payee.merchant(name: 'Shop'),
    ));
    await halvor.flush();
    expect(delivered, hasLength(1));
    expect(errors, isEmpty);
    await halvor.close();
  });
}
