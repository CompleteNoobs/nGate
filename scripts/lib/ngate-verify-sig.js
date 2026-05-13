#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// ngate-verify-sig.js — Hive ECDSA signature verifier (Node helper)
// ─────────────────────────────────────────────────────────────────────────────
//
// Phase 3.2 calls out to this from bash to verify a single Hive posting-key
// signature. We use @hiveio/dhive (same library v4call uses everywhere),
// mirroring the verify-button logic in server-sign.html.
//
// USAGE:
//     echo '{"payload":"...","signature":"...","pubkey":"STM..."}' \
//       | node ngate-verify-sig.js
//
// INPUT  (stdin, JSON object):
//     payload   — the canonical "|"-joined string that was signed
//     signature — hex-encoded compact signature from v4call-server.json
//     pubkey    — Hive posting public key (STM... format)
//
// OUTPUT (stdout):
//     "true"  — signature is valid
//     "false" — signature is invalid OR an error occurred
//
// Errors print to stderr; stdout always emits a single "true" or "false" so
// the caller can rely on a binary result.
// ─────────────────────────────────────────────────────────────────────────────

const dhive = require('@hiveio/dhive');

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => input += d);
process.stdin.on('end', () => {
  try {
    const { payload, signature, pubkey } = JSON.parse(input);
    if (typeof payload   !== 'string' || !payload)   throw new Error('missing payload');
    if (typeof signature !== 'string' || !signature) throw new Error('missing signature');
    if (typeof pubkey    !== 'string' || !pubkey)    throw new Error('missing pubkey');

    const hash = dhive.cryptoUtils.sha256(payload);
    const pk   = dhive.PublicKey.fromString(pubkey);
    const sig  = dhive.Signature.fromString(signature);
    const ok   = pk.verify(hash, sig);
    console.log(ok ? 'true' : 'false');
  } catch (e) {
    process.stderr.write('verify-sig error: ' + e.message + '\n');
    console.log('false');
  }
});
