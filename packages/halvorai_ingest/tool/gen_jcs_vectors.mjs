// Regenerates test/fixtures/jcs-vectors.json from the TypeScript SDK's canonicalize(), so the
// Dart implementation is checked against the reference rather than against hand-typed values.
//
//   node tool/gen_jcs_vectors.mjs ../../../ingest-js > test/fixtures/jcs-vectors.json
//
// Needs Node 22.18 or later (type stripping) and a checkout of halvorAI/ingest-js.
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const jsRepo = resolve(process.argv[2] ?? '../../../ingest-js');
const { canonicalize } = await import(
  pathToFileURL(resolve(jsRepo, 'vendor/schema/canonical.ts')).href
);

// IEEE 754 bit patterns from RFC 8785 appendix B, plus a few extra edge cases.
const numberBits = [
  '0000000000000000', '8000000000000000', '0000000000000001', '8000000000000001',
  '7fefffffffffffff', 'ffefffffffffffff', '4340000000000000', 'c340000000000000',
  '4430000000000000', '44b52d02c7e14af5', '44b52d02c7e14af6', '44b52d02c7e14af7',
  '444b1ae4d6e2ef4e', '444b1ae4d6e2ef4f', '444b1ae4d6e2ef50', '3eb0c6f7a0b5ed8c',
  '3eb0c6f7a0b5ed8d', '41b3de4355555553', '41b3de4355555554', '41b3de4355555555',
  '41b3de4355555556', '41b3de4355555557', 'becbf647612f3696', '43143ff3c1cb0959',
  '3ff0000000000000', '4059000000000000', '3fb999999999999a', '3e7ad7f29abcaf48',
  '3eb0c6f7a0b5ed8e', '4415af1d78b58c40', '7fe0000000000000',
];

const view = new DataView(new ArrayBuffer(8));
const numbers = numberBits.map((bits) => {
  view.setBigUint64(0, BigInt(`0x${bits}`));
  return { bits, expected: canonicalize(view.getFloat64(0)) };
});

const objects = [
  '{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\\u20ac$\\u000F\\u000aA\'\\u0042\\u0022\\u005c\\\\\\"\\/","literals":[null,true,false]}',
  '{"\\u20ac":"Euro Sign","\\r":"Carriage Return","\\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\\ud83d\\ude00":"Emoji: Grinning Face","\\u0080":"Control","\\u00f6":"Latin Small Letter O With Diaeresis"}',
  '{"b":[3,{"z":1,"a":[]}],"a":{},"":"empty key","A":"upper"}',
  '{"controls":"\\u0000\\u0001\\b\\t\\n\\u000b\\f\\r\\u001f\\u007f","lone":"\\ud800x\\udfff","quote":"say \\"hi\\""}',
  '[56,{"d":true,"10":null,"1":[]}]',
  '{"ints":[0,-1,9007199254740991,-9007199254740991,100,1e2,-0]}',
].map((json) => ({ json, expected: canonicalize(JSON.parse(json)) }));

process.stdout.write(`${JSON.stringify({ numbers, objects }, null, 2)}\n`);
