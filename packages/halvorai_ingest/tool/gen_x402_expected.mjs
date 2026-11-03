// Regenerates test/fixtures/x402/expected.json from the Node.js SDK's x402 mappers, so the Dart
// port is checked against the reference rather than hand-written values.
//
//   (cd ../ingest-js && npm run build)
//   node tool/gen_x402_expected.mjs ../../../ingest-js > test/fixtures/x402/expected.json
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const jsRepo = resolve(process.argv[2] ?? '../../../ingest-js');
const x402 = await import(pathToFileURL(resolve(jsRepo, 'dist/x402.js')).href);
const fixture = (name) =>
  JSON.parse(readFileSync(new URL(`../test/fixtures/x402/${name}.json`, import.meta.url), 'utf8'));

const required = fixture('payment-required');
const payload = fixture('payment-payload');
const context = x402.settlementContext({
  accept: payload.accepted,
  nonce: payload.payload.authorization.nonce,
  resource: payload.resource,
});

// The requested event's id is random; the test compares it with the id replaced.
const requested = x402.mapPaymentRequired(required, 'x402-client');
const placeholder = (event) =>
  JSON.parse(JSON.stringify(event).replaceAll(event.id, 'evt_REQUESTED'));

const expected = {
  requested: placeholder(requested),
  authorized: x402.mapPaymentPayload(payload, 'x402-client', undefined, 'evt_REQUESTED'),
  settled: x402.mapSettlementResponse(fixture('settlement-success'), context, 'x402-client'),
  failed: x402.mapSettlementResponse(fixture('settlement-failure'), context, 'x402-client'),
  // Without the payload, a settlement has no token address: it is reported, not recorded.
  settledWithoutContext: (() => {
    try {
      return x402.mapSettlementResponse(fixture('settlement-success'), {}, 'x402-client');
    } catch (err) {
      return { throws: err.message };
    }
  })(),
};
process.stdout.write(`${JSON.stringify(expected, null, 2)}\n`);
