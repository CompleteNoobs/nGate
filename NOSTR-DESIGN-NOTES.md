# NOSTR-DESIGN.md — Nostr Integration Design for v4call

> **Status:** Design notes only. Not implemented. Post-v0.17, post-HiveSigner, post-mobile work.
>
> **Why this exists:** Capturing the architectural design for Nostr integration before context fades, so future-me can pick it up cleanly when the time comes. Same discipline as the federation spec — design first, build later, ship in order.

---

## Why Nostr at All

v4call already has working federation (presence, paid DMs, calls, payments) over WebSocket. Nostr does not replace this. It adds a **fast, redundant discovery channel** layered on top of the existing Hive-based server announcement system.

**The single concrete problem Nostr solves:** the 0–2 hour latency on discovering new federation peers via Hive directory scans drops to 1–30 seconds via Nostr relay push.

**Strictly additive, not replacement.** Hive remains the canonical "this server is real" record. Nostr is the speed layer.

**Honest framing:** the discovery latency improvement is real but oversold in isolation — server discovery is a rare event, so cosmetic on that axis alone. The deeper wins are:
- Reduced Hive RPC load
- An independent failure-mode channel (if Hive RPC misbehaves, Nostr still works; if Nostr relays misbehave, Hive still works)
- A reusable substrate that future v4call-adjacent broadcasts (presence, status, etc.) can also use without inventing new infrastructure

**Not solving:** real-time presence (already fast via federation WS), encrypted DMs (already work), payments (Hive-native).

---

## Core Concepts (One-Paragraph Refresher)

A **Nostr relay** is a dumb pub/sub server that stores signed JSON events and forwards them to subscribers. Relays do not talk to each other — the "network" is built by clients writing to and reading from many relays in parallel. **Events** are signed JSON blobs with a `kind` number identifying the type. **Pubkeys** are the only identity. There is no central authority and no relay coordination — just a protocol.

Read NIP-01 (the core spec) and NIP-78 (parameterized replaceable events) before building. Skip the rest until needed.

---

## Architecture Overview

```
   ─────────────────────────────────────────────────────────────
   Hive truth layer (existing — unchanged)
   ─────────────────────────────────────────────────────────────
   • server-announce posts (now with NOSTR_PUBKEY: line added)
   • v4call-rates posts
   • Hive-Engine token balances
   ─────────────────────────────────────────────────────────────
                         │
                         │ (read by)
                         ▼
   ─────────────────────────────────────────────────────────────
   Policy daemon (new — small standalone service)
   ─────────────────────────────────────────────────────────────
   • Scans Hive every N minutes for v4call-tagged posts
   • Extracts NOSTR_PUBKEY field from each
   • Optionally checks token balance / HP / etc.
   • Writes structured whitelist file(s) to disk
   ─────────────────────────────────────────────────────────────
                         │
                         │ (consumed by)
                         ▼
   ─────────────────────────────────────────────────────────────
   strfry relay with write-policy plugin (new — managed infra)
   ─────────────────────────────────────────────────────────────
   • On every incoming event, plugin checks:
       - Is event.kind permitted?
       - Is event.tag matching expected v4call tag?
       - Is event.pubkey in the relevant whitelist?
   • Accept iff all yes; reject otherwise
   • Forward accepted events to subscribers
   ─────────────────────────────────────────────────────────────
                         │
                         │ (subscribed to by)
                         ▼
   ─────────────────────────────────────────────────────────────
   v4call servers (existing server.js — small Nostr client added)
   ─────────────────────────────────────────────────────────────
   • Publish own announcement to configured relays
   • Subscribe to configured relays for v4call-server events
   • On new event: fetch verify URL, validate, queue for operator approval
   ─────────────────────────────────────────────────────────────
                         │
                         │ (resilience layer)
                         ▼
   ─────────────────────────────────────────────────────────────
   Public Nostr relays (relay.damus.io, nos.lol, etc.)
   ─────────────────────────────────────────────────────────────
   • Same publish/subscribe; events stored without policy filtering
   • Backup channel if v4call-operated relays go down
   ─────────────────────────────────────────────────────────────
```

**Separation of concerns:**
- Hive = truth
- Daemon = policy
- Relay = enforcement
- Server.js = naive pub/sub client
- Public relays = resilience fallback

If gating rules change, only the daemon changes. The other components don't care.

---

## Design Decisions Locked In

### 1. Each server has its own Nostr keypair

Not a per-operator key, not a shared key. **One Nostr keypair per v4call server**, generated automatically on first startup, stored in `data/nostr-key.json` (chmod 600, in `.gitignore`).

**Rationale:** matches v4call's "server as an entity" model. Operators can run multiple servers under one Hive identity, and each server has its own independent Nostr identity. Avoids coupling server identity to a human's social-network identity.

### 2. Cross-reference via Hive announce post

The Nostr pubkey gets pasted into the existing Hive `server-announce` post:

```
NOSTR_PUBKEY:npub1abc...xyz
```

This is the security trick that makes the design robust. An attacker who steals a Nostr key still can't fake announcements — verifying servers cross-check the Hive post (which the attacker can't modify without the Hive key) and reject mismatches.

**Hive = trust root. Nostr = speed layer.** Belt-and-braces philosophy, same as v4call already has elsewhere.

### 3. Bootstrap flow is one-time, then automatic

```
1. Operator starts updated server (post-Nostr-integration version)
2. Server detects no nostr-key.json exists → generates keypair
3. Server prints pubkey to logs:
   "Add NOSTR_PUBKEY:npub1abc... to your Hive announce post"
4. Operator visits /server-announce.html, adds line, re-publishes
5. Server detects pubkey now matches → starts publishing/subscribing
6. Done forever (until operator chooses to rotate)
```

Server detects "my pubkey isn't in my Hive announce post yet" and prints loud warning. Doesn't block startup — graceful degradation.

### 4. Use kind 30078 (parameterized replaceable events)

NIP-78 defines this kind for arbitrary application data. Using `d` tag = server domain means *only the latest announcement per domain* is kept by relays — re-announcements replace, don't pile up.

Event shape:

```json
{
  "kind": 30078,
  "tags": [
    ["d", "v4call.com"],
    ["t", "v4call-server"],
    ["protocol", "0.4"]
  ],
  "content": "{\"verify_url\":\"https://v4call.com/.well-known/v4call-server.json\",\"hive_account\":\"v4call\",\"announced_at\":\"2026-05-05T12:00:00Z\"}",
  "pubkey": "...",
  "sig": "..."
}
```

### 5. Multi-relay publish, deduplicate on read

Default relay list ships in `.env.example`. Each server publishes the same announcement to all configured relays. Subscribers receive duplicates and dedupe by event ID. Standard Nostr pattern.

### 6. Server-side only — never browsers

All Nostr logic lives in `server.js`. Browsers do not connect to relays directly. This:
- Avoids browser-side Nostr key management
- Avoids CORS / browser WebSocket issues
- Keeps federation a server-to-server concept (consistent with rest of v4call)
- Keeps browsers dumb (good for security)

---

## The Three Variants of Gating (For Future Reference)

Not all need to ship at once. Listed in increasing complexity.

### Variant 1: Identity-Gated *(MVP)*

**Rule:** Nostr pubkey must be referenced in a `server-announce` post by a Hive account.

**Use case:** Server discovery channel (`t=v4call-server`). Only real v4call servers can publish.

**Cost to enter:** A Hive post + Nostr key = essentially free. The cost is being a real, claimed entity.

**This is what the MVP integration ships with.**

### Variant 2: Stake-Gated

**Rule:** Pubkey must belong to a Hive account holding ≥ N tokens (HP, liquid HIVE, or Hive-Engine token like CNOOBS).

**Use case:** Federated user broadcasts (`t=v4call-presence`, `t=v4call-broadcast`) — wider participation than just servers, but with anti-spam cost.

**Trade-off:** Token price drift. If CNOOBS goes 10x, gate excludes everyone who isn't a whale. If 0.1x, spammers buy in cheap. Solutions exist (USD-denominated thresholds, dynamic adjustment) but each adds complexity.

**Don't ship until there's a real use case demanding it.**

### Variant 3: Composite-Gated

**Rule:** Different event kinds/tags have different requirements.

Example:
- `t=v4call-server` → identity-gated (Variant 1)
- `t=v4call-presence` → stake-gated, ≥ 1 CNOOBS (Variant 2 cheap)
- `t=v4call-broadcast` → stake-gated, ≥ 100 CNOOBS (Variant 2 premium)

**The relay becomes a shared messaging substrate for the entire CompleteNoobs ecosystem.** Any future Hive-aligned project can use the same relay infrastructure with appropriate gates.

**Future-state design. Don't build until the use cases force it.**

---

## Connection to Existing Token-Utility Story

From v4call README: *"This is a real wedge for creator economies: stake your token, distribute it to your community, then run a server (or use one) where holders get paid access / room access / posting rights via on-chain balance checks."*

**The relay design is the same wedge applied at the federation/messaging substrate layer instead of inside one app.**

Token holders gain utility *across the ecosystem* (any v4call-adjacent service using the relay), not just within v4call itself. Stronger token thesis than the current README.

Mention in marketing/roadmap when this ships, not before.

---

## Honest Trade-offs to Remember

These are the gotchas I'll forget if I don't write them down:

1. **Relay reliability is mediocre.** Public relays go down, rate-limit, change moderation policies, delete old events. Mitigation: publish to multiple. Subscribe from multiple. De-dupe.

2. **Token price drift breaks fixed-amount stake gates.** Variant 2 needs a price-aware threshold or periodic recalibration if it ships.

3. **Whitelist freshness vs. RPC load is a real tuning trade-off.** 30-min refresh = annoying lag for new entrants. 30-sec refresh = hammers Hive RPC. Caching with reactive invalidation (block-stream subscription) is the clever middle path.

4. **Policy relays re-introduce a soft gatekeeper.** Anyone can run a competing relay with different policy, but if v4call's recommended relays all enforce the same rule, that's effectively one decision point. Same trade-off as Bitcoin nodes / email servers — fine, but not maximally decentralized.

5. **The "2 hours → 2 seconds" speedup is real but partially cosmetic.** Server discovery is a rare event. The deeper wins are reduced RPC load and parallel-channel resilience, not raw latency.

6. **Don't go all-in on self-operated relays.** Use them for clean policy-enforced discovery, but ALSO publish to 2–3 public relays for redundancy. If your three relays go down, public relays carry announcements as backup.

7. **Build the spike standalone first.** A 100-line Node.js script using `nostr-tools` that publishes and subscribes to two public relays will teach more in a day than weeks of spec reading.

---

## Suggested Implementation Order

When the time comes (NOT NOW):

1. **Spike (1–2 days):** Standalone Node.js script. Connect to 2 public relays, publish kind 30078, subscribe, log everything. Goal: feel the protocol.
2. **Self-hosted relay (1–2 days):** Stand up `strfry` in Docker on a VPS. Connect spike script to it. Verify events flow.
3. **Policy plugin (2–3 days):** Write strfry write-policy plugin that reads a whitelist file. Test with hardcoded list.
4. **Policy daemon (2–3 days):** Standalone service. Scans Hive for `server-announce` posts, extracts `NOSTR_PUBKEY`, writes whitelist. Run on schedule.
5. **v4call server integration (1 week):** Add Nostr client to `server.js`. Generate key on first boot. Publish on startup + every 6h. Subscribe with filter. Plumb discovered peers into existing `/admin-peers.html` approval flow.
6. **Update `/server-announce.html`:** Add `NOSTR_PUBKEY:` line generation.
7. **Documentation:** Update WalkThrough.wiki Step 17 with Nostr discovery info. Document recommended relay list.
8. **Ship as v0.20 (or whenever appropriate).**

Total estimate: ~3 weeks of focused work, not counting unknowns. Real estimate: 6+ weeks given other priorities. **This is a multi-version arc, not a single sprint.**

---

## Default Configuration (Tentative)

For `.env.example` when this ships:

```bash
# ── Nostr Discovery (optional, defaults sensibly) ─────────
# Comma-separated Nostr relay WebSocket URLs.
# Recommended: include at least one v4call-operated relay
# AND at least two public relays for redundancy.
NOSTR_RELAYS=wss://relay.v4call.com,wss://relay.completenoobs.com,wss://relay.damus.io,wss://nos.lol

# How often to re-publish own announcement (in hours).
# Re-publishing protects against relay event drops.
NOSTR_REPUBLISH_HOURS=6

# Set to "false" to disable Nostr integration entirely.
# Server still functions normally on Hive-only discovery.
NOSTR_ENABLED=true
```

Existing `FEDERATION_PEERS` continues to work; Nostr is purely additive.

---

## What This Design Is NOT

Worth saying explicitly to keep scope contained:

- **Not a replacement for Hive.** Hive remains the canonical record.
- **Not a Nostr social-network presence.** v4call doesn't post notes, doesn't follow users, doesn't render Nostr feeds. Just discovery.
- **Not a payment channel.** Payments stay on Hive. Lightning integration is out of scope.
- **Not browser-side.** Browsers continue to talk only to their home server.
- **Not real-time chat.** Direct messaging continues over existing federation WebSocket.
- **Not for end-users to think about.** Operators configure relays; users see nothing change.

Anything tempting outside that scope: write it down separately. Don't let it leak in.

---

## Open Questions To Resolve Before Building

Notes-to-self for the future build session:

1. **Recommended public relay list.** Which 2–3 to ship as defaults? Need to pick relays known for kind 30078 reliability and reasonable retention policies.

2. **Relay-operator policy plugin language.** Bash? Python? Node? strfry supports any. Probably Node given v4call is already Node — code reuse, shared deps.

3. **What happens when an operator rotates their Nostr key?** Old key still in Hive announce → mismatch → confusion. Need a graceful key-rotation flow. Probably: new key in Hive → republish to relay with old key + new key + signed transition note → wait for confirmation period → drop old key.

4. **Discovery via Nostr without a Hive cross-reference.** What if a peer publishes via Nostr but has no Hive announce post? Reject? Quarantine? Probably: queue with low-confidence flag, don't auto-approve, surface to operator with "Nostr-only, unverified" badge.

5. **Federation protocol bump?** Probably not — Nostr is purely outside the existing federation WS protocol. v0.4 stays valid. But worth confirming.

6. **Relay storage policy.** strfry can be configured to keep events forever OR expire by age/kind. Server announcements should probably be kept indefinitely. Presence events should probably expire after a few minutes. Different retention per kind.

7. **Should the v4call-operated relay be open to the public** (accepts subscription queries from anyone, but only accepts WRITE from whitelisted pubkeys)? Probably yes — read-public, write-restricted is the right pattern. Lets external observers see v4call ecosystem state without needing approval.

---

## Related Future Work (Separate Documents Eventually)

If/when these get serious enough, they get their own design docs:

- **Local Hive HAF node operations.** Out of scope for current scale (public RPCs are sufficient). Educational walk-through eventually planned for completenoobs.com — explicitly a side quest, not a main-quest dependency. Worth revisiting when running ≥3 Hive-dependent services that could share infrastructure.
- **Token-balance caching daemon.** When/if Variant 2 gating ships. SQLite-backed cache + Hive block-stream subscription for reactive updates.
- **Cross-protocol broadcasts.** If the relay becomes a CompleteNoobs ecosystem substrate, design how multiple apps share it without stepping on each other's tag namespaces.

---

## References

- **NIP-01:** https://github.com/nostr-protocol/nips/blob/master/01.md (core protocol)
- **NIP-78:** https://github.com/nostr-protocol/nips/blob/master/78.md (parameterized replaceable events for app data)
- **strfry:** https://github.com/hoytech/strfry (production-quality relay implementation)
- **nostr-tools (Node.js):** https://github.com/nbd-wtf/nostr-tools
- **v4call existing federation spec:** [FEDERATION-BUILD-SPEC.md](./FEDERATION-BUILD-SPEC.md)
- **v4call project context:** [CLAUDE.md](./CLAUDE.md)

---

## Status Log

- **2026-05-05** — Initial design captured during architecture discussion. Not yet implemented. Slotted as post-v0.17 / post-HiveSigner / post-mobile work. Possible v0.20 candidate but no commitment.
