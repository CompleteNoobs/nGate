#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// ngate-verify-nostr-event.mjs — Nostr event verifier (Node ESM helper)
// ─────────────────────────────────────────────────────────────────────────────
//
// Reads a single Nostr event (JSON object) from stdin and prints "true" or
// "false" to stdout based on whether:
//   1. The event.id matches sha256(canonical([0, pubkey, created_at, kind, tags, content]))
//   2. The event.sig schnorr-verifies against the event.pubkey
//
// Uses nostr-tools (same library as the browser pages — guaranteed identical
// semantics across all surfaces).
//
// USAGE:
//     echo '{"kind":30078,"pubkey":"abc…","created_at":…,"tags":[…],"content":"…","id":"…","sig":"…"}' \
//       | node lib/ngate-verify-nostr-event.mjs
//
// OUTPUT (stdout): exactly "true" or "false"
// Errors go to stderr; stdout always emits one of the two strings.
//
// .mjs extension because nostr-tools v2 ships ESM only — Node 18+ supports
// ESM via the .mjs extension regardless of package.json `type` field.
// ─────────────────────────────────────────────────────────────────────────────

import { verifyEvent } from 'nostr-tools';

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', () => {
  try {
    const ev = JSON.parse(input);
    if (typeof ev !== 'object' || ev === null) throw new Error('input is not a JSON object');
    if (typeof ev.id     !== 'string') throw new Error('missing event.id');
    if (typeof ev.sig    !== 'string') throw new Error('missing event.sig');
    if (typeof ev.pubkey !== 'string') throw new Error('missing event.pubkey');
    if (typeof ev.kind   !== 'number') throw new Error('missing event.kind');
    const ok = verifyEvent(ev);
    console.log(ok ? 'true' : 'false');
  } catch (e) {
    process.stderr.write('verify-nostr-event error: ' + e.message + '\n');
    console.log('false');
  }
});
