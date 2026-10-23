/// Signed, attributed payment events for AI agents.
///
/// HalvorAI records each payment an agent makes, with the agent, the owner it acted for, the
/// instruction it followed and the network proof that came with it. It is never in the
/// payment path: [HalvorClient.emit] returns at once and never throws.
library;

export 'src/canonical.dart' show CanonicalError, canonicalize;
export 'src/client.dart'
    show
        ClientStats,
        EnvelopeSink,
        ErrorHandler,
        HalvorClient,
        SdkError,
        SdkErrorCode,
        defaultRetryDelays;
export 'src/context.dart'
    show
        AgentContext,
        AgentRef,
        InstructionChannel,
        InstructionRef,
        OwnerRef,
        OwnerType,
        currentContext,
        withAgentContext;
export 'src/hash.dart' show evidenceSha256, hashInstruction;
export 'src/ids.dart' show newEventId;
export 'src/models.dart';
export 'src/redact.dart' show ExtraPattern, containsPan, redactDeep, redactText;
export 'src/sign.dart' show SourceKey, signEvent, verifyEvent;
export 'src/spool.dart' show MemorySpool, Spool;
export 'src/transport.dart'
    show
        DeliveryFatal,
        DeliveryOk,
        DeliveryOutcome,
        DeliveryRetry,
        DeliveryTooLarge,
        EventTransport,
        ForwardingTransport,
        HalvorApiTransport,
        IngestResult,
        SignedEnvelope,
        apiKeyEnvironment,
        productionEndpoint,
        sandboxEndpoint;
export 'src/validate.dart' show validateEvent;
export 'src/time.dart' show formatUtc;
export 'src/version.dart' show packageVersion, sdkName;
