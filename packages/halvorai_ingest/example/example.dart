// Offline quickstart: no account needed. Events are signed with a key made here and handed to
// a sink instead of the API.
import 'dart:convert';

import 'package:halvorai_ingest/halvorai_ingest.dart';

Future<void> main() async {
  final sourceKey = await SourceKey.generate(); // private; keep it in secure storage

  final halvor = HalvorClient(
    sourceKey: sourceKey,
    environment: Environment.test,
    sink: (envelopes) => print(const JsonEncoder.withIndent('  ').convert(envelopes)),
  );

  await withAgentContext(
    const AgentContext(
      agent: AgentRef(id: 'agt_travel_12', name: 'Travel booking agent'),
      owner: OwnerRef(id: 'own_u_4410', type: OwnerType.person, country: 'US'),
      instruction:
          InstructionRef(id: 'task_8890', text: r'Book a return flight to Austin under $500'),
    ),
    () async {
      halvor.emit(const EventInput.settled(
        payment: Payment(
          paymentId: 'pi_3QxAbCdEfGhIjKlM',
          amount: Amount.minor('41200', 'USD'),
          ref: StripeRef(paymentIntent: 'pi_3QxAbCdEfGhIjKlM'),
        ),
        payee: Payee.merchant(name: 'Example Airways'),
      ));
    },
  );

  await halvor.close();
}
