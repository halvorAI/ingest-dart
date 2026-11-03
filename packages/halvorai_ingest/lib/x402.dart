/// Records x402 v2 payments made over `package:http` as signed, attributed events.
///
/// ```dart
/// final http = HalvorX402Client(halvor); // give this to your x402 client as its HTTP client
/// ```
library;

export 'src/x402/client.dart' show HalvorX402Client;
export 'src/x402/decode.dart' show decodePaymentHeader, encodePaymentHeader;
export 'src/x402/map.dart'
    show
        X402Adapter,
        X402SettlementContext,
        mapPaymentPayload,
        mapPaymentRequired,
        mapSettlementResponse;
