# Scoping: dis-cot-gateway as a standalone service (not a TAK Server plugin)

**Status:** Scoping only — no code written against this plan yet. Captured
2026-09-11 so whoever forks or starts a new project for this has the
reasoning, not just the conclusion.

**Question this answers:** does `dis-cot-gateway` need to be a TAK Server
Java plugin, or could it be a standalone service — and if we build one,
should it share tech with the EASE stack so EASE can eventually pull it in?

**Short answer:** it doesn't need to be a plugin. Build the replacement in
Nest.js/TypeScript (matching EASE, not the Python originally considered),
as a standalone sibling service that can run against bare TAK Server with
no EASE stack present, but is tech-compatible enough to fold into EASE
later with minimal rework.

---

## 1. Does this need to be a TAK Server plugin?

No. Read through all 12 source files under
`dis-cot-gateway/src/main/java/tak/server/plugins/` — eleven of them are
pure protocol/math logic with zero dependency on the TAK Server SDK:

| File | What it does | TAK-SDK dependency |
|---|---|---|
| `config/GatewayConfig.java` | YAML → typed config | None |
| `cot/CotListener.java` | Raw TCP/UDP socket listeners | None |
| `cot/CotEventExtractor.java` | Pulls `<event>...</event>` from a TCP byte stream | None |
| `cot/CotValidator.java` | DOM-parse + attribute/schema checks | None |
| `cot/SimCotPublisher.java` | UDP/multicast fan-out | None |
| `dis/DisListener.java` | UDP + multicast-join listener | None |
| `dis/DisPduParser.java` | Decodes an Entity State PDU (via `open-dis` Java lib) | None (third-party lib, not TAK SDK) |
| `entity/Entity.java`, `entity/EntitySource.java` | Plain data holder | None |
| `mapping/DisToCotMapper.java` | Entity → CoT XML, override lookup | None |
| `mapping/GeoUtils.java` | WGS84 ECEF↔LLA, velocity→speed/course | None |
| `routing/LoopGuard.java` | Provenance tag + `DIS-` UID prefix check | None |
| `DisCotGatewayPlugin.java` | Wiring + `sendCotToTak()` | **Yes — the only one** |

The only SDK-dependent call is `sendCotToTak()`: `getConverter().cotStringToDataMessage(...)`
+ `send(...)`, which injects a message directly onto TAK's internal bus
targeting an explicit `groups` set (`PLUGIN_GROUPS`, default `__ANON__`)
without needing a client cert enrolled in those groups. That's the one thing
being in-process buys you.

It isn't load-bearing, because TAK Server already has a standard way to
accept an external CoT feed with no plugin at all: add a dedicated
`<input>` to CoreConfig — exactly what `init-tak-config.sh` /
`post-start.sh` already do for `ENABLE_TLS` / `ENABLE_PLAINTEXT_TAK`:

```xml
<input _name="discotgateway" protocol="stcp" port="18089" auth="anonymous"/>
```

`protocol="stcp"` (not plain `tcp`) is what makes it bidirectional/broadcast
— same requirement already documented for the existing plaintext input.
This repo already proves the "skip the plugin, hit TAK's native input
directly" path works: `dis-cot-gateway/scripts/send_cot_to_tak_plaintext.py`
sends straight into TAK's plaintext CoT input today. There's a second,
independent precedent for this too — see §4.

`LoopGuard`'s provenance-tag half only matters because the plugin is
subscribed to every message TAK routes via `onMessage()`, which today does
nothing but log ("V1 does not translate TAK→DIS"). A standalone service was
never subscribed to that firehose, so there's nothing to guard against
unless a future version adds CoT→DIS. Keep the `DIS-` UID prefix
convention; drop the provenance tag.

### What's lost vs. gained by dropping the plugin

**Lost:**
- Direct group-targeted injection bypassing cert-based ACL — replaced by
  whichever group the dedicated input maps to (identical in practice to
  today's `__ANON__` default)
- Shows up in `/Marti/plugins/` admin UI — gone; it's a process/container
  now, monitored by its own logs/health check
- Starts/stops in lockstep with TAK Server's process lifecycle — gone
  (arguably a win, see below)

**Gained:**
- No `tak-server-sdk-5.8` vendored jar (~30MB), no Gradle/Java build, no
  TAK-version SDK coupling on every TAK Server upgrade
- Independent restart/deploy — no more `docker compose up -d --build` on
  the whole TAK Server container for a plugin-only change
- Same external ports/wire protocol as today — every existing test script
  (`test_all_ports.py`, `local_gateway_test.py`,
  `send_dis_category_matrix.py`, etc.) keeps working unchanged; they're all
  already black-box, protocol-level tools

### New cost this introduces

The plugin never held an outbound network connection (in-process call, no
socket). A standalone service does: it needs a persistent TCP connection to
TAK's new dedicated input, with reconnect-on-drop logic. Not hard, but it's
genuinely new code, not a straight port.

### DIS PDU parsing — the one real dependency

Today this rides on `edu.nps.moves.dis` (open-dis Java). This project only
ever needs one PDU type (Entity State PDU), fixed ~144-byte layout, already
hand-encoded as a test fixture (`test_all_ports.py`'s `DIS_ES_HEX`
constant) — so decoding it is well-scoped either way. See §5 for why this
stopped being an open risk once the tech decision changed to Nest.js.

---

## 2. Deployment shape (still applies regardless of language)

Add it as its own service in `docker-compose.yml` (own Dockerfile, own
`restart: unless-stopped`), sibling to `tak`/`db`/`init` rather than baked
into the TAK container — keeps "one `docker compose up -d --build`" for the
whole stack while making the gateway genuinely independent underneath.

---

## 3. Phase 2/3: an override-management UI

Once this isn't a plugin anymore, the editor (a person setting overrides)
and the consumer (the process converting DIS→CoT) can live in the **same
process** — no more file-watch polling (`OVERRIDE_RELOAD_SECONDS`) needed;
an override typed into a UI updates the live map immediately, with the
on-disk copy as a durability/export mechanism instead of the primary
channel.

**Architecture (one process, three parts sharing state directly):**
1. DIS/CoT listeners (phase 1) — build an `Entity` per inbound PDU.
2. A live entity registry — upsert every `Entity` into an in-memory table
   keyed by DIS UID (`site-app-entity`): callsign, kind/domain/category/
   affiliation signature, first/last-seen time, which override level
   currently resolves its CoT type. Expire entries some time after they go
   stale so the registry doesn't grow forever.
3. An API + UI serving that registry and the override maps.

**API sketch:**
- `GET /entities` — grouped by signature by default: live count, example
  callsigns, resolved CoT type, which override (if any) produced it
- `GET /entities/{uid}` — one specific entity
- `POST /overrides/category` `{aff, kind, domain, category?, cotType}`
- `POST /overrides/unit` `{callsign, cotType}`
- matching `DELETE`s; `GET /overrides` for a settings view
- push updates via SSE/WebSocket rather than polling

**UI:** default view groups by signature (matches how
`cotTypeOverrides` actually works — keyed by
`aff-kind-domain[-category]`, not by individual UID), with a drill-down to
override one specific callsign (`unitNameOverrides`, exact-match, checked
first). For picking a symbol instead of typing a raw CoT type string —
worth reusing whatever renders SIDC codes today (see §4) rather than
introducing a separate library.

**New costs this adds:** needs auth (this changes what symbols render for
everyone watching the feed — don't leave it a bare unauthenticated port);
needs the registry TTL/expiry sweep mentioned above; "last write wins" is
fine for a single-operator tool, not worth building real concurrency
control for.

---

## 4. What EASE already has (discovered while scoping phase 2/3)

The user asked for phase 2/3 to share tech with EASE "so we can be
compatible or allow the EASE app to pull in what we're building." Checking
the actual EASE repo (`Documents/ease`, not checked into this repo) turned
up much more overlap than expected.

**`ease-sim-service`** (Nest.js/TypeScript) already has:
- DIS PDU parsing via the **`open-dis` npm package** (v1.3.5) — a proven
  dependency, not something to hand-roll
- Full per-country DIS enumeration tables
  (`dis/enumerations/data/countries/*.ts`, one file per nation)
- An adapter pattern (`SimulatorAdapter` interface —
  `transformEntityState`/`transformWeaponFired`) normalizing different
  simulator dialects (CPE, JCATS, generic) into a common entity-state shape
- A `simulation-state` module (controller + service) — very likely already
  the "current state of every live entity" registry phase 2 needs
- A `symbol_mapping.csv` asset with exactly the columns this project's
  override table needs (`unit_name, dis_id, dis_enum_string,
  SIDC_mapping`) — **currently just an empty header row, unpopulated
  scaffolding**
- An existing Server-Sent-Events pattern
  (`external-connections-sse.controller.ts`) — the same mechanism phase 2's
  live entity list would want
- MongoDB (`ease-mongo`) as its primary store

**What it does NOT have:** any CoT/TAK output. `external-integrations.module.ts`
only registers `DisModule` (ingest) and `CpeModule` — nothing pushes to
TAK. That gap is real and is exactly what this project fills.

**Separately found:** `EASEtoTAK-blufor.py` / `-opfor.py`
(`Documents/git/python/`) are an already-running, independent bridge —
polling EASE's GeoServer WFS layer every 30s and pushing CoT into TAK's
native 8089 input via mTLS client cert. Second live precedent for "external
client into TAK's native input, no plugin needed," on a different (WFS/
GeoJSON, not DIS) source path. Out of scope for this project — nothing here
changes or supersedes those scripts.

**Also noted:** EASE VR's mil-sym pipeline plan
(`~/.cursor/plans/ease_mil-sym_pipeline_*.plan.md`) references a
`SidcSymbolServiceBaseUrl` — a point-only SIDC→image render service already
in use elsewhere in the EASE ecosystem. Worth reusing for the phase-3
symbol picker instead of introducing a new rendering library, if reachable
from `ease-app`.

---

## 5. Revised tech decision

Build in **Nest.js/TypeScript**, not Python:
- Matches `ease-sim-service` / `ease-api-v2` / `ease-app`. `ease-api-v1`
  (Flask) is explicitly EASE's "legacy" tier — not the direction to add
  new things in.
- Use `open-dis` (npm) for PDU parsing — removes the "hand-roll a DIS
  parser" risk item from the original (Python-based) scope entirely, since
  EASE already depends on and exercises this exact library.
- Structure as a **standalone sibling service** (a new `apps/`-style Nest.js
  app, matching the monorepo convention) rather than bolting directly onto
  `ease-sim-service` — keeps it deployable against bare TAK Server with no
  Mongo/Postgres/GeoServer (what `H2TAK_Server` does today), while being
  trivially foldable into EASE later since the stack is identical.
- Outbound-to-TAK design is unchanged from §1: dedicated CoreConfig
  `<input>`, persistent reconnecting TCP client.

**Storage** stays pluggable rather than hard-requiring Mongo: use
`symbol_mapping.csv`/Mongo when running alongside EASE, fall back to a
local file when it's just bare TAK Server. **Decided 2026-09-11:**
pluggable with local-file fallback — confirmed, this repo's default
deployment is bare TAK Server with no Mongo present.

**Frontend:** Vue — ideally a page inside `ease-app` when deployed
alongside EASE, a standalone Vue page otherwise.

---

## 6. Decided vs. still open

**Decided:**
- Data source is **raw DIS**, not EASE's own API/WFS — works with any
  DIS-speaking simulator, not just EASE, and keeps this project's original
  premise intact. `EASEtoTAK-blufor/opfor.py` (EASE-API-sourced) stays a
  separate, parallel bridge; this decision doesn't touch it.
- Tech stack: Nest.js/TypeScript + `open-dis` npm, standalone sibling
  service, Vue frontend.
- Storage: pluggable, local-file fallback (no Mongo hard-requirement) — see
  §5.
- **This repo (`H2_TAK_Server_Docker`) is the standalone service's home** —
  not just a scope doc holding pen. Scaffold the Nest.js app here, with its
  own docker-compose bringing up bare TAK Server + gateway.
- **Cutover, not parallel run:** the existing `dis-cot-gateway` Java plugin
  will not be deployed alongside this service — it's a full replacement,
  not an A/B. This removes the port-18089 concern raised during review
  (§1's example CoreConfig `<input>` reused that number, which collided
  with the plugin's own external-facing `cot.inbound.tcp.port`; since the
  plugin is retired, not co-running, reusing 18089 for the new dedicated
  input is fine).
- **Network exposure:** the new dedicated TAK input is published to the
  host, same as the existing 8087/8089 pattern (not internal-docker-network-only).

**Still open (resolve before starting a build):**
- Whether the standalone service ever gets merged directly into
  `ease-sim-service`'s codebase, or stays a permanently-separate sibling
  service that EASE optionally deploys alongside itself.
- Whether the phase-3 symbol picker can actually reach EASE's existing
  SIDC render service, or needs its own.
- Migration bookkeeping: `deploy/docker/prepare-tak-docker.sh`,
  `init-tak-config.sh`'s `ENABLE_DIS_COT_GATEWAY` block,
  `write-plugin-yaml.sh`, and `plugin-config/*.yaml` (all in the
  `H2TAK_Server` repo) exist to build/stage/configure the Java plugin —
  once this service replaces it, that tooling needs to be removed or
  repointed. Not yet inventoried as concrete tasks.

---

## 7. Summary table

| Phase | What | Tech |
|---|---|---|
| 1 — Gateway | DIS listener → `Entity` → CoT XML → persistent client into a dedicated TAK CoreConfig `<input>` | Nest.js/TS, `open-dis` npm, standalone sibling service |
| 2 — Live registry | In-memory (or Mongo-backed) table of currently-seen entities/signatures, REST + SSE API | Same service, EASE's existing SSE pattern |
| 3 — Override UI | Table grouped by signature, per-unit drill-down, symbol picker | Vue — a page in `ease-app` when deployed alongside EASE, standalone otherwise |

Nothing in this document has been built yet. `dis-cot-gateway` continues to
run as a TAK Server plugin, as documented in
[`dis-cot-gateway/README.md`](../dis-cot-gateway/README.md) and
[`HANDOVER.md`](HANDOVER.md), until someone picks this scope up.
