/// Typed input for an Agent Payment Event (APE v0.1, https://schema.halvorai.com). These only
/// build the JSON; the client fills ids, source and context, then validates the final event.
library;

import 'context.dart';
import 'hash.dart';
import 'time.dart';

enum EventType {
  requested('payment.requested', PaymentStatus.requested),
  authorized('payment.authorized', PaymentStatus.authorized),
  settled('payment.settled', PaymentStatus.settled),
  failed('payment.failed', PaymentStatus.failed),
  refunded('payment.refunded', PaymentStatus.refunded),
  disputed('payment.disputed', PaymentStatus.disputed);

  const EventType(this.wire, this.status);

  final String wire;

  /// The payment status an event of this type carries unless one is given.
  final PaymentStatus status;
}

enum PaymentStatus {
  requested,
  authorized,
  settled,
  failed,
  refunded,
  disputed;

  String get wire => name;
}

enum Environment {
  test,
  live;

  String get wire => name;
}

/// A CAIP-19-style asset on a CAIP-2 network, such as USDC on `eip155:8453`.
class Asset {
  const Asset({required this.network, required this.address, this.symbol, this.decimals});

  final String network;
  final String address;
  final String? symbol;
  final int? decimals;

  Map<String, Object?> toJson() => {
        'network': network,
        'address': address,
        if (symbol != null) 'symbol': symbol,
        if (decimals != null) 'decimals': decimals,
      };
}

/// An amount as a decimal integer string, never a float.
sealed class Amount {
  const Amount(this.value);

  /// [value] in the currency's minor unit (cents for USD): `Amount.minor('41200', 'USD')`.
  const factory Amount.minor(String value, String currency, {Asset? asset}) = MinorAmount;

  /// [value] in the asset's smallest unit (wei, or 10^-6 USDC).
  const factory Amount.atomic(String value, Asset asset, {String? currency}) = AtomicAmount;

  final String value;

  Map<String, Object?> toJson();
}

class MinorAmount extends Amount {
  const MinorAmount(super.value, this.currency, {this.asset});

  final String currency;
  final Asset? asset;

  @override
  Map<String, Object?> toJson() => {
        'value': value,
        'unit': 'minor',
        'currency': currency,
        if (asset != null) 'asset': asset!.toJson(),
      };
}

class AtomicAmount extends Amount {
  const AtomicAmount(super.value, this.asset, {this.currency});

  final Asset asset;
  final String? currency;

  @override
  Map<String, Object?> toJson() => {
        'value': value,
        'unit': 'atomic',
        'asset': asset.toJson(),
        if (currency != null) 'currency': currency,
      };
}

/// The rail's own references. The subclass decides `payment.rail`.
sealed class RailRef {
  const RailRef();

  String get rail;

  Map<String, Object?> toJson();
}

Map<String, Object?> _compact(Map<String, Object?> m) => {
      for (final e in m.entries)
        if (e.value != null) e.key: e.value,
    };

class StripeRef extends RailRef {
  const StripeRef({
    this.account,
    this.paymentIntent,
    this.charge,
    this.refund,
    this.dispute,
    this.sharedPaymentToken,
  });

  final String? account;
  final String? paymentIntent;
  final String? charge;
  final String? refund;
  final String? dispute;
  final String? sharedPaymentToken;

  @override
  String get rail => 'stripe';

  @override
  Map<String, Object?> toJson() => _compact({
        'account': account,
        'payment_intent': paymentIntent,
        'charge': charge,
        'refund': refund,
        'dispute': dispute,
        'shared_payment_token': sharedPaymentToken,
      });
}

class CardRef extends RailRef {
  const CardRef(
      {this.authorizationId, this.transactionId, this.networkTransactionId, this.processor});

  final String? authorizationId;
  final String? transactionId;
  final String? networkTransactionId;
  final String? processor;

  @override
  String get rail => 'card';

  @override
  Map<String, Object?> toJson() => _compact({
        'authorization_id': authorizationId,
        'transaction_id': transactionId,
        'network_transaction_id': networkTransactionId,
        'processor': processor,
      });
}

class X402Ref extends RailRef {
  const X402Ref(
      {this.scheme, this.network, this.nonce, this.txHash, this.facilitator, this.paymentFlow});

  final String? scheme;
  final String? network;
  final String? nonce;
  final String? txHash;
  final String? facilitator;
  final String? paymentFlow;

  @override
  String get rail => 'x402';

  @override
  Map<String, Object?> toJson() => _compact({
        'scheme': scheme,
        'network': network,
        'nonce': nonce,
        'tx_hash': txHash,
        'facilitator': facilitator,
        'payment_flow': paymentFlow,
      });
}

class MppRef extends RailRef {
  const MppRef({this.method, this.challengeId, this.paymentIntent, this.txHash});

  final String? method;
  final String? challengeId;
  final String? paymentIntent;
  final String? txHash;

  @override
  String get rail => 'mpp';

  @override
  Map<String, Object?> toJson() => _compact({
        'method': method,
        'challenge_id': challengeId,
        'payment_intent': paymentIntent,
        'tx_hash': txHash,
      });
}

class StablecoinRef extends RailRef {
  const StablecoinRef({this.network, this.txHash, this.logIndex});

  final String? network;
  final String? txHash;
  final int? logIndex;

  @override
  String get rail => 'stablecoin';

  @override
  Map<String, Object?> toJson() =>
      _compact({'network': network, 'tx_hash': txHash, 'log_index': logIndex});
}

class BankTransferRef extends RailRef {
  const BankTransferRef({this.scheme, this.endToEndId, this.pisp});

  final String? scheme;
  final String? endToEndId;
  final String? pisp;

  @override
  String get rail => 'bank_transfer';

  @override
  Map<String, Object?> toJson() =>
      _compact({'scheme': scheme, 'end_to_end_id': endToEndId, 'pisp': pisp});
}

class Payment {
  const Payment({
    required this.paymentId,
    required this.amount,
    required this.ref,
    this.status,
    this.failureReason,
    this.description,
    this.category,
  });

  /// Stable across the payment's lifecycle, so its events can be joined.
  final String paymentId;
  final Amount amount;

  /// Decides the rail: `StripeRef` makes a `stripe` payment, `X402Ref` an `x402` one.
  final RailRef ref;

  /// Defaults to the status matching the event type.
  final PaymentStatus? status;

  /// Required when the status is `failed`.
  final String? failureReason;
  final String? description;
  final String? category;

  Map<String, Object?> toJson(PaymentStatus defaultStatus) => {
        'payment_id': paymentId,
        'rail': ref.rail,
        'amount': amount.toJson(),
        'status': (status ?? defaultStatus).wire,
        'rail_ref': ref.toJson(),
        if (failureReason != null) 'failure_reason': failureReason,
        if (description != null) 'description': description,
        if (category != null) 'category': category,
      };
}

class Wallet {
  const Wallet({required this.network, required this.address});

  /// CAIP-2, such as `eip155:8453`.
  final String network;
  final String address;

  Map<String, Object?> toJson() => {'network': network, 'address': address};
}

enum PayeeType {
  merchant('merchant'),
  apiProvider('api_provider'),
  wallet('wallet'),
  business('business'),
  person('person');

  const PayeeType(this.wire);

  final String wire;
}

/// Who was paid. Needs at least one of [name], [wallet] or [id].
class Payee {
  const Payee({
    required this.type,
    this.name,
    this.id,
    this.website,
    this.country,
    this.mcc,
    this.wallet,
    this.resourceUrl,
  });

  const Payee.merchant(
      {required String name, String? id, String? website, String? country, String? mcc})
      : this(
            type: PayeeType.merchant,
            name: name,
            id: id,
            website: website,
            country: country,
            mcc: mcc);

  const Payee.apiProvider({String? name, String? resourceUrl, Wallet? wallet, String? id})
      : this(
            type: PayeeType.apiProvider,
            name: name,
            resourceUrl: resourceUrl,
            wallet: wallet,
            id: id);

  const Payee.wallet(Wallet wallet, {String? name})
      : this(type: PayeeType.wallet, wallet: wallet, name: name);

  final PayeeType type;
  final String? name;
  final String? id;
  final String? website;
  final String? country;

  /// Four-digit merchant category code.
  final String? mcc;
  final Wallet? wallet;
  final String? resourceUrl;

  Map<String, Object?> toJson() => {
        'type': type.wire,
        if (name != null) 'name': name,
        if (id != null) 'id': id,
        if (website != null) 'website': website,
        if (country != null) 'country': country,
        if (mcc != null) 'mcc': mcc,
        if (wallet != null) 'wallet': wallet!.toJson(),
        if (resourceUrl != null) 'resource_url': resourceUrl,
      };
}

enum InstrumentType {
  card('card'),
  agenticToken('agentic_token'),
  stripeSpt('stripe_spt'),
  wallet('wallet'),
  bankAccount('bank_account');

  const InstrumentType(this.wire);

  final String wire;
}

/// What the agent paid with. Never a full card number; [last4] at most.
class Instrument {
  const Instrument({
    required this.type,
    this.network,
    this.last4,
    this.par,
    this.tokenRef,
    this.wallet,
    this.issuer,
  });

  final InstrumentType type;
  final String? network;
  final String? last4;
  final String? par;
  final String? tokenRef;
  final Wallet? wallet;
  final String? issuer;

  Map<String, Object?> toJson() => {
        'type': type.wire,
        if (network != null) 'network': network,
        if (last4 != null) 'last4': last4,
        if (par != null) 'par': par,
        if (tokenRef != null) 'token_ref': tokenRef,
        if (wallet != null) 'wallet': wallet!.toJson(),
        if (issuer != null) 'issuer': issuer,
      };
}

enum EvidenceKind {
  ap2PaymentMandate('ap2.payment_mandate'),
  ap2CheckoutMandate('ap2.checkout_mandate'),
  viChain('vi.chain'),
  tapSignature('tap.signature'),
  x402PaymentPayload('x402.payment_payload'),
  x402Settlement('x402.settlement'),
  mppReceipt('mpp.receipt'),
  stripeObject('stripe.object'),
  agenticTokenMetadata('agentic_token.metadata'),
  kyaAttestation('kya.attestation');

  const EvidenceKind(this.wire);

  final String wire;
}

enum EvidenceFormat {
  sdJwt('sd-jwt'),
  kbSdJwt('kb-sd-jwt'),
  jws('jws'),
  httpSignature('http-signature'),
  json('json');

  const EvidenceFormat(this.wire);

  final String wire;
}

/// A proof attached verbatim, with its digest. Exactly one of a value or a URI.
class Evidence {
  const Evidence._(this.kind, this.format, this.sha256, {this.value, this.uri, this.capturedAt});

  /// A JSON proof (`format: json`); the digest is over its canonical form.
  factory Evidence.json(EvidenceKind kind, Map<String, Object?> value, {DateTime? capturedAt}) =>
      Evidence._(kind, EvidenceFormat.json, evidenceSha256(value),
          value: value, capturedAt: capturedAt);

  /// A compact proof such as an SD-JWT or JWS; the digest is over its UTF-8 bytes.
  factory Evidence.text(EvidenceKind kind, EvidenceFormat format, String value,
          {DateTime? capturedAt}) =>
      Evidence._(kind, format, evidenceSha256(value), value: value, capturedAt: capturedAt);

  /// A proof stored elsewhere; [sha256] is `sha256:<hex>` of its content.
  const Evidence.uri(EvidenceKind kind, EvidenceFormat format, String uri,
      {required String sha256, DateTime? capturedAt})
      : this._(kind, format, sha256, uri: uri, capturedAt: capturedAt);

  final EvidenceKind kind;
  final EvidenceFormat format;
  final String sha256;
  final Object? value;
  final String? uri;
  final DateTime? capturedAt;

  Map<String, Object?> toJson() => {
        'kind': kind.wire,
        'format': format.wire,
        if (value != null) 'value': value,
        if (uri != null) 'uri': uri,
        'sha256': sha256,
        if (capturedAt != null) 'captured_at': formatUtc(capturedAt!),
      };
}

class Related {
  const Related({this.previousEventId, this.correctsEventId, this.sessionId});

  final String? previousEventId;
  final String? correctsEventId;
  final String? sessionId;

  Map<String, Object?> toJson() => _compact({
        'previous_event_id': previousEventId,
        'corrects_event_id': correctsEventId,
        'session_id': sessionId,
      });
}

/// One payment event to emit. Agent, owner and instruction default to the current
/// [AgentContext]; set them here to override it for this event.
class EventInput {
  const EventInput({
    required this.type,
    required this.payment,
    required this.payee,
    this.id,
    this.occurredAt,
    this.agent,
    this.owner,
    this.instruction,
    this.instrument,
    this.evidence,
    this.related,
    this.labels,
    this.adapter,
  });

  const EventInput.requested(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.requested,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  const EventInput.authorized(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.authorized,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  const EventInput.settled(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.settled,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  const EventInput.failed(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.failed,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  const EventInput.refunded(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.refunded,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  const EventInput.disputed(
      {required Payment payment,
      required Payee payee,
      String? id,
      DateTime? occurredAt,
      AgentRef? agent,
      OwnerRef? owner,
      InstructionRef? instruction,
      Instrument? instrument,
      List<Evidence>? evidence,
      Related? related,
      Map<String, String>? labels})
      : this(
            type: EventType.disputed,
            payment: payment,
            payee: payee,
            id: id,
            occurredAt: occurredAt,
            agent: agent,
            owner: owner,
            instruction: instruction,
            instrument: instrument,
            evidence: evidence,
            related: related,
            labels: labels);

  final EventType type;
  final Payment payment;
  final Payee payee;

  /// Defaults to a new `evt_` id. Reuse an id to make a retry idempotent.
  final String? id;

  /// Defaults to now.
  final DateTime? occurredAt;

  // No environment field: it is always the client's (see HalvorClient).
  final AgentRef? agent;
  final OwnerRef? owner;
  final InstructionRef? instruction;
  final Instrument? instrument;
  final List<Evidence>? evidence;
  final Related? related;

  /// Up to 20 short string labels.
  final Map<String, String>? labels;

  /// `source.adapter`; adapters set this, and it defaults to `custom`.
  final String? adapter;

  /// The partial event the client completes, in the same shape `emitJson` takes.
  Map<String, Object?> toJson() => {
        'type': type.wire,
        'payment': payment.toJson(type.status),
        'payee': payee.toJson(),
        if (id != null) 'id': id,
        if (occurredAt != null) 'occurred_at': formatUtc(occurredAt!),
        if (agent != null) 'agent': agent!.toJson(),
        if (owner != null) 'owner': owner!.toJson(),
        if (instruction != null) 'instruction': instruction!.toJson(),
        if (instrument != null) 'instrument': instrument!.toJson(),
        if (evidence != null) 'evidence': [for (final e in evidence!) e.toJson()],
        if (related != null) 'related': related!.toJson(),
        if (labels != null) 'labels': {...labels!},
        if (adapter != null) 'source': {'adapter': adapter},
      };
}
