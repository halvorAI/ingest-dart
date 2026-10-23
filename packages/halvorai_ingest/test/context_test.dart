import 'dart:async';

import 'package:halvorai_ingest/halvorai_ingest.dart';
import 'package:test/test.dart';

const _agent = AgentRef(id: 'agt_1');
const _owner = OwnerRef(id: 'own_1', type: OwnerType.person);

void main() {
  test('no context outside withAgentContext', () {
    expect(currentContext(), isNull);
  });

  test('context follows awaits, timers and microtasks', () async {
    await withAgentContext(const AgentContext(agent: _agent), () async {
      await Future<void>.delayed(Duration.zero);
      expect(currentContext()?.agent?.id, 'agt_1');
      final fromTimer = Completer<String?>();
      Timer(Duration.zero, () => fromTimer.complete(currentContext()?.agent?.id));
      expect(await fromTimer.future, 'agt_1');
      expect(await Future.microtask(() => currentContext()?.agent?.id), 'agt_1');
    });
    expect(currentContext(), isNull);
  });

  test('nested contexts merge over the outer one and restore it', () {
    withAgentContext(const AgentContext(agent: _agent, owner: _owner), () {
      withAgentContext(const AgentContext(agent: AgentRef(id: 'agt_2')), () {
        expect(currentContext()?.agent?.id, 'agt_2');
        expect(currentContext()?.owner?.id, 'own_1');
      });
      expect(currentContext()?.agent?.id, 'agt_1');
    });
  });

  test('a sync throw reaches the caller as a throw, not a rejected future', () {
    expect(
      () => withAgentContext(const AgentContext(agent: _agent), () => throw StateError('boom')),
      throwsStateError,
    );
  });

  test('withAgentContext returns the body result', () async {
    expect(withAgentContext(const AgentContext(), () => 42), 42);
    expect(await withAgentContext(const AgentContext(), () async => 'ok'), 'ok');
  });
}
