# NOSTR-DESIGN.md — Nostr Integration Design for v4call

> **Status:** Design notes only. Not implemented. Federation reliability is the current main quest; this doc captures the design that solves it.
>
> **Why this exists:** Capturing the architectural design before context fades, so future-me can pick it up cleanly when the time comes. Same discipline as the federation spec — design first, build later, ship in order.

---

## Document Structure

- **Part 1 — Architecture B:** Nostr for server discovery only. Conservative addition. Originally framed as v0.20.
- **Part 2 — Architecture C:** Server-only federation via Nostr. Replaces federation WS for presence/discovery. **This is the architecture the project is now committed to building toward.**
- **Part 3 — Token Mechanics for Federation Access:** The economic gating layer. Currently baking — multiple mechanisms documented, no numbers locked in.
- **Part 4 — Phased Implementation Plan:** The 8-phase build path with realistic timelines.
- **Part 5 — Open Questions, References, Status Log.**

---

# PART 1 — ARCHITECTURE B: NOSTR FOR SERVER DISCOVERY ONLY

## Why Nostr at All

v4call has working federation (presence, paid DMs, calls, payments) over WebSocket. But the federation has reliability problems — users sometimes don't show across servers, sometimes don't connect. **Nostr offers a fundamentally different transport model (pub/sub through dumb relays) that is more robust for this use case than mesh-WebSocket.**

Architecture B is the conservative entry point: keep federation WS doing everything it does today, add Nostr ONLY for the discovery layer. Hive remains the canonical "this server is real" record. Nostr is a fast, redundant discovery channel.

**This is the entry point of the implementation plan, even though Architecture C is the destination.**

---

## Core Concepts (One-Paragraph Refresher)

A **Nostr relay** is a dumb pub/sub server that stores signed JSON events and forwards them to subscribers. Relays do not talk to each other — the "network" is built by clients writing to and reading from many relays in parallel. **Events** are signed JSON blobs with a `kind` number identifying the type. **Pubkeys** are the only identity. There is no central authority and no relay coordination — just a protocol.

**Kind numbers** are like stickers on toys — they tell relays and subscribers what type of event this is, before opening it. Numbers in different ranges have different relay behaviours:
- `0` — special profile event
- `1–999` — regular events (posts, DMs, reactions)
- `10000–19999` — replaceable (newer replaces older)
- `20000–29999` — ephemeral (relays don't store)
- `30000–39999` — parameterized replaceable (replaceable per `d` tag identifier)

v4call uses `kind: 30078` (NIP-78 — generic app data, parameterized replaceable) with a `d` tag = the server domain. Relays only keep the latest event per `d` tag. Re-announcements replace; no piling up.

Read NIP-01 (the core spec) and NIP-78 (parameterized replaceable events) before building.

---

## Architecture B Overview

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
   • Optionally checks token balance / stake / fee transfers
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
       - Is event tag matching expected v4call tag?
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
- server.js = naive pub/sub client
- Public relays = resilience fallback

---

## Architecture B — Design Decisions Locked In

### 1. Each server has its own Nostr keypair

Per-server, not per-operator, not shared. Generated automatically on first startup, stored in `data/nostr-key.json` (chmod 600, in `.gitignore`).

**Rationale:** matches v4call's "server as an entity" model. Operators can run multiple servers under one Hive identity, each with independent Nostr identity. Avoids coupling server identity to a human's social-network identity.

### 2. Cross-reference via Hive announce post

The Nostr pubkey gets pasted into the existing Hive `server-announce` post:

```
NOSTR_PUBKEY:npub1abc...xyz
```

This is the security trick that makes the design robust. An attacker who steals a Nostr key still can't fake announcements — verifying servers cross-check the Hive post (which the attacker can't modify without the Hive key) and reject mismatches.

**Hive = trust root. Nostr = speed layer.**

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

### 4. Use kind 30078 (parameterized replaceable events)

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

All Nostr logic lives in `server.js`. Browsers do not connect to relays directly. Keeps federation a server-to-server concern, consistent with rest of v4call.

---

# PART 2 — ARCHITECTURE C: SERVER-ONLY FEDERATION VIA NOSTR

## Why This Architecture (The Real Quest)

Architecture B adds Nostr alongside federation WS. **Architecture C replaces the WS-based federation transport with Nostr-mediated server gossip.** This is the architecture that actually solves the "users sometimes don't show, sometimes don't connect" problem — by removing the flaky transport entirely.

**Critical scoping:** users do NOT touch Nostr. They have no Nostr keys. They don't know Nostr exists. Their browser only ever connects to their home server's WebSocket, exactly as today. **Nostr is an internal, server-only mechanism.** Users just see "the federation works better now."

This scoping eliminates:
- User-side Nostr key management
- Browser-side relay connections
- User identity / privacy / guest-user complexity

What remains is the elegant core: **servers gossip with each other through token-gated relays, instead of through fragile point-to-point WebSocket meshes.**

---

## Architecture C Overview

```
   ┌────────────────────────────────────────────────────────────┐
   │  USER LAYER (unchanged from today's v4call)                │
   ├────────────────────────────────────────────────────────────┤
   │                                                            │
   │  cnoobz logs into v4call.com via browser                   │
   │  guest33 logs into call.completenoobs.com via browser      │
   │                                                            │
   │  Each user only ever talks to their home server's WS.      │
   │  Users have no Nostr keys, no awareness of Nostr.          │
   │                                                            │
   └────────────────────────────────────────────────────────────┘
                  │                │                │
              (existing WS)    (existing WS)    (existing WS)
                  │                │                │
                  ▼                ▼                ▼
   ┌────────────────────────────────────────────────────────────┐
   │  SERVER LAYER (existing server.js + new Nostr module)      │
   ├────────────────────────────────────────────────────────────┤
   │                                                            │
   │  Each server publishes:                                    │
   │   "I have these users right now: [foo, bar, cnoobz]"       │
   │   Periodically + on every join/leave (throttled).          │
   │                                                            │
   │  Each server subscribes to other servers' user lists.      │
   │  Maintains a local "fed user directory" from subscriptions │
   │  Cross-fed user list shown in lobby UI.                    │
   │                                                            │
   └────────────────────────────────────────────────────────────┘
                  │                │                │
                  ▼                ▼                ▼
   ┌────────────────────────────────────────────────────────────┐
   │  NOSTR RELAY LAYER (token-gated, server-only)              │
   ├────────────────────────────────────────────────────────────┤
   │                                                            │
   │  nostr.v4call.com  nostr.completenoobs.com  nostr.hive-    │
   │                                              book.com      │
   │                                                            │
   │  Whitelist: servers meeting token requirements +           │
   │  with valid server-announce post + matching NOSTR_PUBKEY.  │
   │                                                            │
   │  All other Nostr traffic rejected at policy plugin.        │
   │                                                            │
   └────────────────────────────────────────────────────────────┘
```

**The relay layer is a private servers-only club.** Not a public Nostr substrate. Not user-facing. **It's a token-gated message bus for servers to gossip with each other.**

---

## Architecture C — Design Decisions Locked In

### Q1: How does cnoobz on v4call.com contact guest33 on call.completenoobs.com?

**Decision: Option (a) — Click-through via existing Hive auth.**

The lobby shows cross-fed users as clickable links: `guest33 (call.completenoobs.com)`. Clicking opens that server in a new tab. Hive auth makes account portability seamless — cnoobz logs in there too via Hive Keychain.

**Rationale:** simplest, ships first, no new server-to-server contact-request protocol needed. Server-to-server contact requests via Nostr (option b) and deep-link invites (option c) can be added later if user demand justifies them.

### Q3: How does the server publish the user list, and how often?

**Decision: Option (b) — Throttled updates.**

Server batches changes — at most one publish per N seconds (initial value: 30s). If 5 users join in 10 seconds, only one publish goes out at the end. Plus a heartbeat-style republish every 60s in case relays dropped events.

**Rationale:** scales cleanly. Full-list republish on every change (option a) is fine for small federations but generates avoidable traffic at larger scale. Starting with throttled updates avoids retrofitting later.

### Q6: Does the relay run on the same server as v4call or a separate domain?

**Decision: Separate domain and infrastructure.**

- `call.completenoobs.com` — serves HTML/JS/CSS + runs server.js (user-facing)
- `nostr.completenoobs.com` — runs strfry relay only (federation-facing)

**Rationale:**
- Different uptime profiles (relay can hiccup without breaking user experience)
- Different scaling needs (relay is light; user server is heavier)
- Different security boundaries (relay is exposed to Nostr ecosystem; user server is more controlled)
- Different software stacks (strfry is C++; v4call is Node.js)
- Cost is negligible — both are small VPS-class workloads

---

## Architecture C — Event Schema

User list publication (the core new event type):

```json
{
  "kind": 30078,
  "tags": [
    ["d", "call.completenoobs.com:users"],
    ["t", "v4call-presence"]
  ],
  "content": "{\"users\":[\"cnoobz\",\"foo\",\"bar\"],\"updated_at\":\"2026-05-05T14:32:00Z\"}",
  "pubkey": "<server's nostr pubkey>",
  "sig": "<signed by server's nostr key>"
}
```

The `d` tag = `domain:users` means *"this is the user list for call.completenoobs.com, replaceable."* Each republish replaces the previous one. Relays only keep the latest. Subscribers always see current state.

---

## Architecture C — The "User Travels, Not Messages" Pattern

A wisdom note worth preserving: this architecture follows the same pattern as email, XMPP, and other successful federated systems.

**The principle:** federation is for **finding and routing**, not for being the conversation channel itself.

- Discovery is broadcast (everyone announces themselves to relays)
- Initial contact is routed through federation (the click-through link)
- Ongoing communication is direct (user moves to the destination server)

This is structurally how email works. SMTP routes the first email to the recipient's mail server (initial contact); ongoing conversation happens at the recipient's inbox at *their* server. **Reply goes the same way.**

v4call applies this correctly: cross-fed presence is broadcast via Nostr; actual conversations happen on the user's home server (or whichever server they're currently logged into).

---

## Architecture C — What Stays Server-Side, Always

**These do NOT migrate to Nostr, ever:**

- WebRTC signaling (SDP, ICE candidates) — stays direct, server-mediated
- Paid DMs and call initiation — stays server-side with escrow
- Hive payment broadcasts — stays Hive-native
- Rate limiting and moderation — stays server-side, operator-controlled
- Lobby/room chat content — stays inside the originating server (cross-fed visibility is presence-only, not message-content)
- User authentication via Hive Keychain — unchanged

**This is the principle:** Nostr handles broadcast and discovery. Server.js handles real-time, paid, moderated, and signaling concerns. Each piece runs on infrastructure that suits it.

---

# PART 3 — TOKEN MECHANICS FOR FEDERATION ACCESS

## Status: Baking

This section captures the design space for economic gating of relay access. **No specific numbers are locked in.** The mechanisms are documented; the parameters get tuned during operational experience.

**Token used in MVP/testing:** CNOOBS (already exists). A dedicated federation token may be created later, once mechanics are proven.

---

## Design Principle: One Mechanism Per Job

Most token mechanics fail because designers bundle multiple jobs into one mechanism. Better approach: one mechanism per job, tunable independently.

| Job | Best Mechanism |
|---|---|
| **Anti-spam barrier** | Stake CNOOBS (locks tokens, prevents rotation attacks) |
| **Anti-zombie / commitment** | Stake (cooldown is the commitment) |
| **Operational funding** | HBD or token subscription transfer to operator account |
| **Demand pressure for token** | Optional burn (not required — supplemental) |

---

## The Four Mechanisms

### Mechanism A — Hold (liquid balance check)
*"Account holds ≥ N CNOOBS in liquid balance."*

- **Strengths:** simple, recoverable (sell anytime), no tooling needed
- **Weaknesses:** **rotation attack** — holder transfers tokens to next account, claims fresh trial, repeats indefinitely
- **Use case:** lightweight signal, NOT a primary gate

### Mechanism B — Stake (locked balance check)
*"Account has ≥ N CNOOBS staked, with cooldown unstaking."*

- **Strengths:** real commitment, defeats rotation attack, on-chain verifiable
- **Weaknesses:** more friction, requires staking enabled on the token
- **Use case:** **primary anti-spam barrier**

### Mechanism C — Burn (track burns to @null)
*"Account has burned ≥ N CNOOBS in last 30 days."*

- **Strengths:** creates demand pressure, deflationary, ecosystem benefit
- **Weaknesses:** non-recoverable cost, fragile to token price swings, doesn't directly fund operations
- **Use case:** **optional supplemental mechanism**, not the primary funding channel

### Mechanism D — Subscribe (transfer to funding account)
*"Account has transferred ≥ X HBD/CNOOBS to funding account in last 30 days."*

- **Strengths:** direct cash flow to operators, predictable, price-stable in HBD
- **Weaknesses:** centralizes funding through receiving account
- **Use case:** **primary operational funding channel**

---

## Notes on Hive-Engine Staking (Important)

**Hive-Engine custom tokens CAN be staked,** but only if `stakingEnabled` was set when the token was configured.

- If staking is enabled: tokens can be staked via `stake` op, unstaked via `unstake` op, with cooldown period that the issuer configured (`unstakingCooldown` in days, `numberTransactions` for split releases).
- If staking is NOT enabled on CNOOBS: the issuer (you) can call `enableStaking` to turn it on, without reissuing the token.

**Action needed before token mechanics ship:** verify CNOOBS staking config via Hive-Engine explorer. If not enabled, run `enableStaking` op. Choose appropriate cooldown — 4 weeks is standard for similar Hive-Engine tokens (LEO, POB use 4 weeks; BEE uses 60 days).

**Real-world reference points for cooldown choice:**
- 7 days = light commitment, easier UX, weaker rotation defense
- 4 weeks = standard, balanced
- 60 days = strong commitment, harsh on operators who change their minds

---

## The Rotation Attack and Its Defense

**The attack (insight from session 2026-05-05):**
> A holder uses 33 tokens to claim a free trial, then transfers the 33 tokens to a fresh account, which claims its own free trial. Repeats indefinitely. **Hold-only gating is gameable.**

**The defense:**
- **Stake-based gating** is rotation-resistant — locked tokens can't be moved fast enough to rotate
- **One trial per Hive account ever** — hard limit, recorded
- **Hive account age requirement** — accounts < 30 days old don't qualify (forces account-creation cost too)
- **Combination:** stake to enter trial + one trial per account ever

---

## Recommended MVP Design (Tentative — Bake Further)

When the time comes to ship token gating (Phase 7), starting position:

1. **Stake ≥ 33 CNOOBS** (anti-spam, anti-rotation, commitment signal)
2. **Subscription: 1 HBD / month** transferred to relay operator's funding account (operational cash flow)
3. **30-day grace period** for new servers — only stake requirement applies during grace, then subscription kicks in
4. **Optional burn rebate:** operators who choose to burn N CNOOBS/month get reduced subscription rate (encourages token economics participation without forcing it)
5. **Per-relay configurable:** each relay operator sets their own thresholds via policy daemon config

**Why 33 is the placeholder number:** symbolic, easy to remember, clearly arbitrary so it signals "this is the mechanism, not the magic number."

**Funding account model — open question:**
- Single global account (`v4call-nostr-network`)? — simpler, but a trust point + key-management critical
- Per-operator accounts (each relay operator runs their own funding account)? — more decentralized, distributes trust, encourages multiple operators

Probably per-operator. Defer decision until Phase 7.

---

## Refined Evolution (Future)

After 6+ months of operation, the simple MVP may evolve toward:
- **Split subscription:** part transferred to operator (funding), part burned (deflation pressure)
- **Quarterly recalibration:** stake/subscription thresholds reviewed periodically based on token price
- **USD-denominated rates:** "burn $X worth of CNOOBS" rather than "burn N CNOOBS" — protects against token price drift
- **Tiered access:** different rates for server-only access vs. server + premium broadcasts

**These are evolution targets, not v0.20-v1.0 work.** Document for later.

---

## Honest Trade-offs to Remember

1. **Token valuation is not a given.** For burn/stake mechanisms to have economic weight, CNOOBS must have value beyond the federation gate. Pure circular value (operators value CNOOBS because federation values CNOOBS because operators value CNOOBS) is fragile.

2. **Token price drift breaks fixed-quantity rates.** A 33-stake gate that costs £2 today could cost £20 in 6 months. Mitigation: USD-denominated, periodic recalibration, or accept the drift as feedback signal.

3. **Burning doesn't directly fund operations.** Burning reduces supply → raises price of remaining tokens → operators sell their holdings → cash. Indirect, slow, dependent on market liquidity. **Subscription transfers fund operations directly. Don't conflate the two.**

4. **Small-scale federation doesn't need this complexity.** Token mechanics make sense when the federation has 5+ unfamiliar operators. With 3 informally-trusted operators, it's premature optimization. **Build the mechanism for the future state; don't deploy until the present state needs it.**

5. **Regulatory framing matters.** Token-with-required-payments-for-access can look like securities in some jurisdictions. Document the utility-only nature clearly, avoid investment-style framing, get UK legal advice before any structured token sale.

---

# PART 4 — PHASED IMPLEMENTATION PLAN

## The Discipline

Each phase produces something working before the next begins. Each phase is independently rollback-able. **Validate the foundation BEFORE building features on top.**

Original draft plan was: learn → build features → token gating. Refined plan separates learning from architecture validation from token mechanics, in that order.

---

## Phase 1 — Learn Nostr as a User
**Duration:** 1 week. **Cost:** £0.

- Generate a Nostr key (nstart.me, Nostrudel)
- Use a Nostr web client (snort.social) for a few days
- Post notes, follow people, send DMs
- Open browser dev tools, watch WebSocket traffic, see real events
- Read NIP-01 (core spec) and NIP-78 (parameterized replaceable)

**Exit criterion:** can explain event/kind/relay/filter without notes.

---

## Phase 2 — Standalone Pub/Sub Spike
**Duration:** 1 week. **Cost:** £0.

- ~100-line Node.js script using `nostr-tools`
- Connects to two public relays (relay.damus.io, nos.lol)
- Generates a test keypair, publishes kind 30078 with `t=v4call-test`
- Runs second instance subscribing for the same tag
- Sees own events round-trip

**Exit criterion:** spike script in a git repo, works on different machines.

---

## Phase 3 — Run Your Own Relay
**Duration:** 1-2 weeks. **Cost:** ~£4/month (small VPS).

- Provision Hetzner CPX11 or equivalent
- Install Docker, deploy strfry from official image
- Domain: `nostr-test.completenoobs.com` (test name, not production)
- TLS via Caddy or Nginx reverse proxy
- Point Phase 2 spike script at the new relay
- Skeleton write-policy plugin that logs but accepts everything

**Exit criterion:** relay has 7+ days uptime, accessible from anywhere, policy plugin logging events.

---

## Phase 4 — One v4call Server Publishes to Nostr
**Duration:** 2-3 weeks.

- Add Nostr-client module to server.js (50-150 lines)
- Auto-generate keypair to `data/nostr-key.json`
- On user join/leave, publish kind-30078 with current user list (throttled per Q3 decision)
- Watch from external Nostr client, see user list update real-time
- **No cross-server logic yet — just one server, observable from outside**

**Exit criterion:** call.completenoobs.com publishes user lists, observable from anywhere.

---

## Phase 5 — Two-Server Presence Federation
**Duration:** 3-4 weeks.

- Roll out Phase 4 module to v4call.com too
- Add subscription logic — each server subscribes to other servers' presence
- Build lobby UI: "users on this server" + "users on the federation" (with click-through per Q1 decision)
- Test with real users
- Compare reliability vs current federation WS

**Exit criterion:** "users sometimes don't show" is measurably better. Numerical comparison in hand.

**🛑 CHECKPOINT:** does this work? If yes → continue. If no → rethink architecture before adding more.

---

## Phase 6 — Policy Daemon and Whitelist
**Duration:** 2-3 weeks.

- Hive-scanning daemon, runs on schedule
- strfry write-policy plugin reads daemon's whitelist file
- Federation gated by Hive announce posts (no token check yet — just identity)
- Verify federation still works with policy enforcement

**Exit criterion:** non-whitelisted Nostr events rejected at relay door; whitelisted ones flow normally.

---

## Phase 7 — Token Mechanics
**Duration:** 2-4 weeks.

- Verify/enable CNOOBS staking config (one-time operational task)
- Add stake-checking to policy daemon (Hive-Engine API)
- Add subscription-checking (transfers to funding account)
- Implement 30-day grace period
- Per-relay configurable rules

**Exit criterion:** federation access genuinely gated by stake + subscription. Test with mock servers that fail/pass the gate.

---

## Phase 8 — Multi-Relay Redundancy
**Duration:** 2-3 weeks.

- Stand up nostr.v4call.com and nostr.completenoobs.com as parallel relays
- Cross-publish from each v4call server to all relays
- Test failover (kill a relay, verify federation continues)
- Document operator setup
- **This is where v0.20 ships.**

**Exit criterion:** federation tolerates any single relay being down without user-visible impact.

---

## Total Calendar Estimate

**14-23 weeks of focused work**, but realistic wall-clock: **6+ months** given other priorities, life, and the non-linear path of "discover unknown unknown, pause, learn, resume." That's not slow. That's the speed of careful work.

---

## Ongoing Practice: "What Did I Learn This Week?"

At the end of each week, write down:
- What surprised me?
- What assumption was wrong?
- What took longer than expected? Shorter?
- What library/pattern/tool did I learn about that I didn't know existed?

These questions force unknown unknowns into the open. Re-read at start of next phase. Patterns emerge. Future planning improves.

---

# PART 5 — OPEN QUESTIONS, REFERENCES, STATUS LOG

## Open Questions (For Future Build Sessions)

1. **Recommended public relay list.** Which 2–3 to ship as defaults for redundancy? Need relays known for kind-30078 reliability and reasonable retention.

2. **Relay-operator policy plugin language.** Bash? Python? Node? strfry supports any. Probably Node given v4call is Node — code reuse, shared deps.

3. **Nostr key rotation flow.** What happens when an operator rotates their Nostr key? Probably: new key in Hive → republish to relay with old + new + signed transition → wait for confirmation period → drop old key.

4. **Discovery via Nostr without Hive cross-reference.** What if a peer publishes via Nostr but has no Hive announce post? Probably: queue with low-confidence flag, surface to operator with "Nostr-only, unverified" badge.

5. **CNOOBS staking config.** Currently unknown whether `stakingEnabled` is set. Verify via Hive-Engine explorer. If not, run `enableStaking` op with appropriate cooldown choice.

6. **Funding account architecture.** Single global `v4call-nostr-network` account vs. per-operator funding accounts. Probably per-operator. Defer to Phase 7.

7. **Federation protocol bump?** Probably not — Nostr is purely outside the existing federation WS protocol. Confirm during Phase 5.

8. **Relay storage policy per kind.** Server announcements: keep indefinitely. Presence events: expire after a few minutes. Different retention per kind in strfry config.

9. **Read-public, write-restricted relay design.** Relay accepts subscription queries from anyone (lets external observers see v4call ecosystem state) but only accepts WRITE from whitelisted pubkeys. Probably yes.

10. **Throttle interval for user-list republishing.** Initial value: 30s. Tune based on Phase 5 operational data.

---

## Default Configuration (Tentative — For Eventual `.env.example`)

```bash
# ── Nostr Federation (optional, defaults sensibly) ─────────
# Comma-separated Nostr relay WebSocket URLs.
# Recommended: include at least one v4call-operated relay
# AND at least two public relays for redundancy.
NOSTR_RELAYS=wss://relay.v4call.com,wss://relay.completenoobs.com,wss://relay.damus.io,wss://nos.lol

# How often to re-publish own announcements (in seconds).
NOSTR_PRESENCE_REPUBLISH_SECONDS=60

# Throttle for user-list updates (no faster than this).
NOSTR_PRESENCE_THROTTLE_SECONDS=30

# Set to "false" to disable Nostr integration entirely.
NOSTR_ENABLED=true
```

---

## What This Design Is NOT

Worth saying explicitly to keep scope contained:

- **Not a replacement for Hive.** Hive remains the canonical record.
- **Not a Nostr social-network presence.** v4call doesn't post notes, doesn't follow users, doesn't render Nostr feeds.
- **Not a payment channel.** Payments stay on Hive. Lightning integration is out of scope.
- **Not browser-side.** Browsers continue to talk only to their home server.
- **Not real-time chat content.** Direct messaging stays on the originating server. Only presence/discovery flows through Nostr.
- **Not for end-users to think about.** Operators configure relays; users see nothing change except "the federation feels more reliable."

---

## References

- **NIP-01:** https://github.com/nostr-protocol/nips/blob/master/01.md (core protocol)
- **NIP-78:** https://github.com/nostr-protocol/nips/blob/master/78.md (parameterized replaceable events)
- **strfry:** https://github.com/hoytech/strfry (production-quality relay)
- **nostr-tools (Node.js):** https://github.com/nbd-wtf/nostr-tools
- **Hive-Engine staking docs:** https://hive-engine.com/ (verify current API)
- **v4call existing federation spec:** [FEDERATION-BUILD-SPEC.md](./FEDERATION-BUILD-SPEC.md)
- **v4call project context:** [CLAUDE.md](./CLAUDE.md)

---

## Status Log

- **2026-05-05 (initial)** — Architecture B captured. Variant 1 (server discovery only) documented as conservative entry point. Slotted as post-v0.17 / post-HiveSigner / post-mobile work. Possible v0.20 candidate.

- **2026-05-07 (this session)** — Major design expansion:
  - **Architecture C added** as the destination architecture: server-only Nostr federation, replacing federation WS for presence/discovery. Users never touch Nostr.
  - **Q1, Q3, Q6 decisions locked in** — click-through contact, throttled updates, separate relay domain.
  - **Token mechanics section added** (Part 3) with the four-mechanism menu (hold, stake, burn, subscribe). Currently baking; no numbers locked.
  - **Rotation attack and stake-based defense** documented.
  - **Hive-Engine staking notes** added with action-needed tag (verify CNOOBS staking config).
  - **8-phase implementation plan** (Part 4) replacing the rough draft order. Phases 1-5 validate architecture; Phases 6-7 add policy and token gating; Phase 8 ships v0.20.
  - **"What did I learn this week?"** practice added as ongoing discipline.
  - **Federation reliability framed as the current main quest.** All other v4call work pauses until federation is solid.
  - **Funding considerations** noted separately — NLnet application targeting June 1 deadline as primary near-term funding path; Hive DHF and consulting as parallel slow-burn channels. Not part of this design doc but tracked alongside the build plan.

- **2026-05-08 (this session)** — Stage 1 + 2 shipped, Stage 3 plan refined:
  - **Stage 1 SHIPPED** — `nostr-relay-with-whitelist.wiki` walkthrough deploys 2 relays (`nostr.v4call.com`, `nostr.hive-book.com`) on Vultr Ubuntu 24.04 + Docker + nostr-rs-relay + Caddy. Whitelist enforces 3-key write gate. Domain rename: `v4call-nostr-gate/` → `nGate/` to match the chosen software name.
  - **Stage 2 SHIPPED** — `nostr-handson.html` + `nostr-handson.wiki`. Bare-metal one-file Nostr learning page (raw WebSockets, click-collapse JSON log, browser-console mirror, NIP-04 DM auto-decrypt). 12-lesson walkthrough teaches the full protocol via the operator's own relays.
  - **Bug class documented and fixed** — `pubkey_whitelist` requires HEX, not bech32 npub. Pasting npubs is a silent failure (relay starts cleanly, every publish rejects). Stage 1 wiki now has a "read this twice" callout at Step 10 + a Common Problems entry. `nostr-gen.html` updated to show hex-pubkey panel open by default with copy button.
  - **Operator tools updated with Nostr fields** — `server-announce.html` and `server-sign.html` now both have a NOSTR card: npub + hex (with bech32 auto-sync) + 5 relay slots (first 2 prefilled with the v4call/hive-book relays). All Nostr fields are optional; operators without a Nostr keypair produce announce-posts and verify-files identical to the old format. The `buildPayload` canonical signing string in `server-sign.html` appends Nostr trailer fields ONLY when at least one is non-empty — pre-Nostr signed JSONs verify unchanged. Querystring chain `server-sign → server-announce` now forwards the Nostr fields too.
  - **Decision: Nostr fields belong in BOTH the signed `v4call-server.json` AND the `v4call-server` Hive announce post.** Discoverers fetching the well-known see the Nostr key claim baked into the signed payload — single fetch for full verification, instead of post + well-known cross-check.
  - **Stage 3 architecture decided: nGate = nostr-rs-relay + cron-rewriter, NOT strfry yet.** Strfry deferred to stage 4+ as the architectural endgame (live policy plugin, no restarts, hot-reload). Stage 3's job is to validate the identity-gate concept end-to-end on existing infrastructure; once proven, migrate.
  - **Stage 3 scope: SERVERS-ONLY.** User-gating relays will eventually exist (rate-editor.html will gain Nostr fields with the same npub↔hex auto-sync) but must run on SEPARATE relays from federation discovery — different trust model, different gate config, different operator decisions. Mixing user-gating with federation-discovery in the same relay would let user-tier noise drown out federation traffic. Future stage when scope is right.
  - **Gate config pattern locked in (mirrors v4call's lobby gate)**: `NGATE_MIN_HP`, `NGATE_MIN_HP_INCLUDE_DELEGATED` (default false — owned-only, prevents whale renting privileges via delegation), `NGATE_MIN_TOKEN_SYMBOL` + `NGATE_MIN_TOKEN_AMOUNT`, `NGATE_MIN_TOKEN_INCLUDE_STAKED`, `NGATE_GATE_ACCOUNT` (default `escrow` — gate the operational account, not the brand-new vanity account), `NGATE_GATE_MODE=or|and`, `NGATE_SEED_PUBKEYS` (always-allowed bootstrap), `NGATE_SCAN_INTERVAL_HOURS` (default 2).
  - **Critical rule for cron robustness: ADD-only on partial failure.** If Hive RPC, Hive-Engine API, or a well-known fetch fails, the cron run can ONLY add new entries. Removals require a clean successful scan. Prevents transient outages from kicking the entire whitelist on a single bad cycle.
  - **Separation of concerns**: nGate is the gate (decides who's allowed to publish on a relay); v4call is the discovery layer (decides which relays to scan). nGate does NOT advertise relay URLs back to v4call servers — v4call servers' own announce posts list their `NOSTR-RELAYS` field and that's what other peers use. This keeps each side composable; one can evolve without breaking the other.
  - **Self-discovery for bootstrap**: a relay operator publishes their own v4call-server post as a regular operator. nGate scans, finds it (or it's in `NGATE_SEED_PUBKEYS`), whitelists. Other operators then find this relay through the operator's own announce. No special bootstrap protocol needed.
  - **Corner cases tracked for stage 3 docs (and v4call backlog where applicable)**:
    - **Escrow can't make transfer (insufficient HP/RC)** — independent of nGate, but worth noting because nGate gate threshold should sit ABOVE the operational HP floor with a clear buffer. Documenting in stage 3 wiki: "the gate is an eligibility check, not a transaction-time check; don't run on fumes." Logged as a v4call backlog item: escrow should expose an HP/RC health check endpoint and refuse to start if it can't fund expected transfer rate.
    - **Same Nostr key in two different v4call-server posts** — collision/forgery. nGate fail-closed, refuse to whitelist either, log loudly.
    - **Nostr key rotation by an existing operator** — there's a window of up to `NGATE_SCAN_INTERVAL_HOURS` where the new key isn't whitelisted yet. Document this explicitly. Operators with shell access to the relay can manually trigger a sync via `ngate-sync now` (planned helper).
    - **Hive node returning anomalous data** (e.g. HP value transitions 1000→0 in one cycle) — log, pause gate decision for that pubkey, don't auto-kick on a single anomaly.
    - **Transient well-known failure** — track consecutive failure count per pubkey; only remove after N consecutive failed scans (default N=3 = 6 hours unreachable).
    - **Operator's own seed list collides with discovered list on same hex** — seed wins; never remove a seed entry via discovery logic.
  - **Open question parked for the build session**: whether nGate should publish a "rejection log" Nostr event (kind 30000-something, signed by the relay's own identity) listing recent rejections + reasons. Defer to stage 3.5; not required for stage 3 to function.
  - **Test plan for stage 3**: HP-based gate first (`NGATE_MIN_HP=3` is fundable today). Cycle through five outcomes — gate-pass, gate-fail, transition-up, transition-down, transient-Hive-failure-no-kick. CNOOBS-token gate test deferred until Hive-Engine staking budget (~1000 BEE) is available. Note: user confirmed staked HIVE works for HP gate testing; delegated-HP path untested.
  - **Implementation language for stage 3 cron script**: bash + jq + curl (single file, no install dependencies, easy to read). Upgrade to a real language during stage 4 / strfry migration. Cron lives inside the relay's docker-compose stack as a sidecar service — one operator-facing knob.
  - **Companion piece needed when v0.18.5+ Nostr work begins**: `rate-editor.html` gets the same NOSTR card as the two operator pages, with the same npub↔hex auto-sync. Already in the v4call planned-features list; mechanical port once that work starts.
