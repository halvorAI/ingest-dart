/// Agent context carried in [Zone] values: the Dart counterpart of Python's `contextvars` and
/// Node's `AsyncLocalStorage`. It follows `await`, futures, timers and streams created inside
/// [withAgentContext], but not callbacks registered outside it (Flutter widget handlers, for
/// one), so wrap the agent's task itself, or pass `agent`/`owner` on the event.
library;

import 'dart:async';

/// Whether the owner is a person or a business.
enum OwnerType {
  person,
  business;

  String get wire => name;
}

/// Where an instruction came from.
enum InstructionChannel {
  chat,
  api,
  schedule,
  email,
  agent,
  other;

  String get wire => name;
}

/// The agent that made the payment.
class AgentRef {
  const AgentRef({required this.id, this.name, this.framework, this.version, this.keyThumbprint});

  final String id;
  final String? name;
  final String? framework;
  final String? version;

  /// RFC 7638 thumbprint of the agent's own key, if it has one.
  final String? keyThumbprint;

  Map<String, Object?> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (framework != null) 'framework': framework,
        if (version != null) 'version': version,
        if (keyThumbprint != null) 'key_thumbprint': keyThumbprint,
      };
}

/// The person or business the agent acted for.
class OwnerRef {
  const OwnerRef(
      {required this.id, required this.type, this.displayName, this.country, this.kycRef});

  final String id;
  final OwnerType type;
  final String? displayName;

  /// ISO 3166-1 alpha-2, upper case.
  final String? country;
  final String? kycRef;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.wire,
        if (displayName != null) 'display_name': displayName,
        if (country != null) 'country': country,
        if (kycRef != null) 'kyc_ref': kycRef,
      };
}

/// The instruction the agent followed. [text] is hashed on this device and never sent.
class InstructionRef {
  const InstructionRef({
    required this.id,
    this.text,
    this.summary,
    this.channel,
    this.issuedAt,
    this.toolCallId,
  });

  final String id;
  final String? text;
  final String? summary;
  final InstructionChannel? channel;

  /// RFC 3339 with an offset.
  final String? issuedAt;
  final String? toolCallId;

  Map<String, Object?> toJson() => {
        'id': id,
        if (text != null) 'text': text,
        if (summary != null) 'summary': summary,
        if (channel != null) 'channel': channel!.wire,
        if (issuedAt != null) 'issued_at': issuedAt,
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

/// Who a payment is attributed to. Any part may be left out; nested contexts fill gaps from
/// the outer one.
class AgentContext {
  const AgentContext({this.agent, this.owner, this.instruction});

  final AgentRef? agent;
  final OwnerRef? owner;
  final InstructionRef? instruction;

  /// [inner] over [outer], part by part.
  static AgentContext merge(AgentContext? outer, AgentContext inner) => AgentContext(
        agent: inner.agent ?? outer?.agent,
        owner: inner.owner ?? outer?.owner,
        instruction: inner.instruction ?? outer?.instruction,
      );
}

final _zoneKey = Object();

/// The current agent context, or null outside [withAgentContext].
AgentContext? currentContext() => Zone.current[_zoneKey] as AgentContext?;

/// Runs [body] with [context] merged over the current one and returns its result. Errors,
/// sync or async, reach the caller unchanged.
R withAgentContext<R>(AgentContext context, R Function() body) => runZoned(
      body,
      zoneValues: {_zoneKey: AgentContext.merge(currentContext(), context)},
    );
