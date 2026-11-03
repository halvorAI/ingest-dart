// Demo backend for the HalvorAI Flutter example. Runs on your machine with no API key:
//
// - POST /halvor/sources and /halvor/events: the two routes an app calls, built with
//   @halvorai/ingest/device exactly as a real backend would be.
// - Behind them, a fake HalvorAI that registers keys and verifies every forwarded signature.
// - GET /premium-data: a pretend x402 resource (402 first, then 200 with a settlement).
// - /admin/*: see what arrived, and take event delivery offline to exercise the app's spool.
//
// The signed-in user is whatever follows "Bearer " in the Authorization header.
import { randomBytes } from 'node:crypto';
import http from 'node:http';
import { deviceRoutes } from '@halvorai/ingest/device';
import { compactVerify, importJWK } from 'jose';

const PORT = Number(process.env.PORT ?? 8787);
const API_KEY = 'hk_test_' + 'demo'.repeat(8); // never leaves this process

// ---------------------------------------------------------------------------------------------
// The fake HalvorAI

const sources = new Map(); // src_ id -> public JWK
const events = []; // { id, type, payment_id, source, verified, event }
let nextSource = 1;

/** RFC 8785: sorted keys, JSON.stringify for everything else. */
function canonicalize(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalize(value[k])}`).join(',')}}`;
}

async function verify(event, sig) {
  const jwk = sources.get(event?.source?.id);
  if (!jwk) return false;
  try {
    const [header, , signature] = sig.split('.');
    const payload = Buffer.from(canonicalize(event), 'utf8').toString('base64url');
    const { protectedHeader } = await compactVerify(`${header}.${payload}.${signature}`, await importJWK(jwk, 'EdDSA'));
    return protectedHeader.kid === event.source.id && protectedHeader.typ === 'ape+jws';
  } catch {
    return false;
  }
}

async function fakeHalvor(url, init) {
  const path = new URL(url).pathname;
  const body = JSON.parse(new TextDecoder().decode(new Uint8Array(await new Response(init.body).arrayBuffer())));
  if (path === '/v1/sources') {
    // Idempotent per public key, as the Flutter backend requirements ask of the real API.
    const existing = [...sources].find(([, jwk]) => jwk.x === body.public_jwk.x);
    const id = existing?.[0] ?? `src_demo_${String(nextSource++).padStart(4, '0')}`;
    sources.set(id, body.public_jwk);
    log(`  HalvorAI registered ${id}${existing ? ' (again: same key)' : ''}`);
    return Response.json({ id }, { status: 201 });
  }
  const results = [];
  for (const { event, sig } of body.events) {
    const verified = await verify(event, sig);
    const duplicate = events.some((e) => e.id === event.id);
    if (!duplicate) {
      events.push({ id: event.id, type: event.type, payment_id: event.payment?.payment_id, source: event.source?.id, verified, event });
    }
    results.push(
      duplicate
        ? { id: event.id, status: 'duplicate' }
        : verified
          ? { id: event.id, status: 'accepted' }
          : { id: event.id, status: 'rejected', error: { code: 'invalid_signature' } },
    );
  }
  log(`  HalvorAI got ${results.length} event(s): ${results.map((r) => r.status).join(', ')}`);
  return Response.json({ results });
}

// ---------------------------------------------------------------------------------------------
// The customer backend

const routes = deviceRoutes({
  apiKey: API_KEY,
  endpoint: 'https://api.halvorai.invalid',
  fetch: fakeHalvor,
  ownerId: (request) => request.headers.get('authorization')?.replace(/^Bearer /, '') || null,
});

let offline = false;

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64');
const REQUIREMENT = {
  scheme: 'exact',
  network: 'eip155:84532',
  amount: '10000',
  asset: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
  payTo: '0x209693Bc6afc0C5328bA36FaF03C514EF312287C',
  maxTimeoutSeconds: 60,
  extra: { name: 'USDC', version: '2', decimals: 6 },
};

function premiumData(req) {
  const signature = req.headers['payment-signature'];
  if (!signature) {
    const required = {
      x402Version: 2,
      error: 'PAYMENT-SIGNATURE header is required',
      resource: { url: `http://localhost:${PORT}/premium-data`, description: 'Premium market data', mimeType: 'application/json' },
      accepts: [REQUIREMENT],
    };
    return { status: 402, headers: { 'payment-required': b64(required) }, body: '{"error":"payment required"}' };
  }
  const payload = JSON.parse(Buffer.from(signature, 'base64').toString('utf8'));
  const settlement = {
    success: true,
    transaction: `0x${randomBytes(32).toString('hex')}`,
    network: REQUIREMENT.network,
    payer: payload.payload?.authorization?.from,
  };
  return { status: 200, headers: { 'payment-response': b64(settlement) }, body: '{"eur_mwh":81.4,"as_of":"today"}' };
}

function log(line) {
  console.log(`${new Date().toISOString().slice(11, 19)} ${line}`);
}

http
  .createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const send = (status, payload, headers = {}) => {
      res.writeHead(status, { 'content-type': 'application/json', ...headers });
      res.end(typeof payload === 'string' || Buffer.isBuffer(payload) ? payload : JSON.stringify(payload));
    };
    const toRequest = () =>
      new Request(`http://localhost:${PORT}${req.url}`, {
        method: 'POST',
        headers: Object.entries(req.headers).filter(([, v]) => typeof v === 'string'),
        body,
      });

    try {
      if (req.method === 'POST' && req.url === '/halvor/sources') {
        const response = await routes.register(toRequest());
        log(`app registered a key -> ${response.status}`);
        return send(response.status, Buffer.from(await response.arrayBuffer()));
      }
      if (req.method === 'POST' && req.url === '/halvor/events') {
        if (offline) {
          log('app sent a batch -> 503 (offline)');
          return send(503, { error: { code: 'unavailable', message: 'demo backend is offline' } });
        }
        const response = await routes.forward(toRequest());
        log(`app sent a batch -> ${response.status}`);
        return send(response.status, Buffer.from(await response.arrayBuffer()));
      }
      if (req.method === 'GET' && req.url === '/premium-data') {
        const out = premiumData(req);
        log(`x402 ${req.headers['payment-signature'] ? 'paid request -> 200' : 'first request -> 402'}`);
        return send(out.status, out.body, out.headers);
      }
      if (req.url === '/admin/offline' && req.method === 'POST') {
        offline = JSON.parse(body.toString() || '{}').offline === true;
        log(`event delivery is now ${offline ? 'OFFLINE' : 'online'}`);
        return send(200, { offline });
      }
      if (req.url === '/admin/events') {
        return send(200, { sources: [...sources.keys()], offline, events: events.map(({ event, ...rest }) => rest) });
      }
      if (req.url === '/admin/reset' && req.method === 'POST') {
        events.length = 0;
        sources.clear();
        offline = false;
        log('reset');
        return send(200, { ok: true });
      }
      send(404, { error: { code: 'not_found', message: req.url } });
    } catch (err) {
      log(`error: ${err.stack ?? err}`);
      send(500, { error: { code: 'internal_error', message: String(err) } });
    }
  })
  .listen(PORT, '127.0.0.1', () => log(`demo backend on http://localhost:${PORT}`));
