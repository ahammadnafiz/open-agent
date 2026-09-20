# Jev Integration Plan

**Status:** Reviewed. Four decisions locked (§0.4). No implementation code written.
**Date:** 2026-09-20
**Branch:** `main` @ `badd005`
**Scope:** Wire `jev-1.13.0` (TypeSafe) into `Harness` as the per-step judgment call.

---

## 0. Read this first: three corrections to the brief

This plan was commissioned with three premises. All three are wrong, and two of them
change the work.

**0.1 — There is no `JEV_API_KEY`.**

The string appears nowhere in this project: not in Swift, not in `docs/`, not in
`SPEC.md`, not in git history across all six commits. The variable this project
actually documents is **`TYPESAFE_API_KEY`** (`docs/jev-api-reference.md:77,895,914`;
`docs/jev-questions.md:16`), with siblings `TYPESAFE_BASE_URL`,
`TYPESAFE_DEFAULT_MODEL`, `TYPESAFE_LOG_LEVEL`.

The confusion is a vendor/model mixup that runs through the whole brief:

| Thing | Name | Evidence |
|---|---|---|
| The **vendor** | TypeSafe | `https://api.typesafe.ai/v1/systemone` |
| The **model** | Jev | `Constants.Models.jev = "jev-1.13.0"` (`Constants.swift:28`) |

You authenticate against TypeSafe. You call Jev. `JEV_API_KEY` is a name that exists
only in the brief.

**A names-only read of `.env` was denied by the permission system three times**
(to this session and to a subagent). One earlier read did succeed and showed a line
beginning `jev` followed by a non-word character — so `jev=` or `jev-api-key=`.
Neither is `TYPESAFE_API_KEY`. **Action required from you:** open `.env` and confirm
the spelling. If the key is stored as `jev-api-key`, note that a hyphenated lowercase
name is not a legal shell identifier and `export` cannot set it — nothing will ever
read it.

`OPENROUTER_API_KEY` is dead weight. ADR 0009 moved planning and vision to the host
agent (`docs/adr/0009-...:13-17`) and took every OpenRouter role with it.

**0.2 — The directory was renamed mid-session.**

`computer-agent` → `open-agent`, matching commit `badd005`. Same repo. Two artifacts
still carry the old name and one of them is a live bug:

- `Constants.swift:274` — `agentProfilePath` points at
  `~/Library/Application Support/computer-agent/zen-profile`, while `SPEC.md:138`
  says `open-agent/zen-profile`. The browser profile holds live session cookies and
  `SPEC.md:479-480` treats profile scoping as a safety boundary. Two candidate paths
  is how an agent ends up driving a profile nobody audited.
- `.build/` holds stale absolute paths to the old directory. Cosmetic; `rm -rf .build`
  clears it.

**0.3 — This is not a greenfield integration. `docs/jev-api-reference.md` already
exists (41KB) and is mostly right, but it contains a fabricated legal clause.**

See §3.

**0.4 — Decisions locked in review (2026-09-20)**

| # | Decision | Chosen | Consequence |
|---|---|---|---|
| D1 | Credential source | **direnv / shell wrapper** | No Swift `.env` parser. `Credentials.swift` is ~8 lines. Re-opens when an `.app` bundle ships (§4.7). |
| D2 | Retry vs step timeout | **Clamp retries to the step deadline** | `RetryPolicy` takes a deadline. Caller learns it was rate-limited, not that "something took too long" (§6.1). |
| D3 | Doc repair timing | **Fix the MCA claim now, batch the rest** | F1 done (§3.1). F2–F5 stay in Lane B. |
| D4 | Candidate ID namespace | **`e`-prefixed: `e0`, `e17`** | Callback JSON changes to `{"e1": "New mail"}`. Keeps candidate IDs out of the integer namespace shared by mark indices and score levels (§7.6). |

---

## 1. What exists today

**1,023 lines of Swift in four files. It builds clean in 3.76s. It cannot do anything.**

| File | Lines | Real? |
|---|---|---|
| `Sources/Harness/Config/Constants.swift` | 423 | Yes. Every threshold, with provenance. Complete. |
| `Sources/OpenAgent/App.swift` | 205 | `@main` shim, arg parser, and a **hardcoded scripted demo** |
| `Sources/OpenAgent/HUD/CursorOverlay.swift` | 199 | Yes. Click-through panel, coordinate flip. |
| `Sources/OpenAgent/HUD/CursorView.swift` | 196 | Yes. Cursor, ring, narration chip, ripple. |

Zero external dependencies (`Package.swift` has no `dependencies:` array) — `SPEC.md:456-457`
calls that a feature. Two targets, `Harness` (headless library) and `OpenAgent`
(executable). Dependency runs one way: `OpenAgent → Harness` (`Package.swift:16`).

**What does not exist**, and is load-bearing for this plan:

- **No `Sources/Harness/Judgment/`.** `JevClient.swift` is specified at
  `docs/build-sequence.md:156` and does not exist. The model this project is built
  around is called from zero lines of code.
- **No networking anywhere.** `rg 'URLSession|URLRequest|Codable|JSONDecoder|https?://'`
  across `Sources/` returns nothing. Not a thin layer — nothing.
- **No error handling convention.** The only hit for `throw|Error|catch|Result<` was
  the word "confidence" in a comment (`Constants.swift:101`). Errors are swallowed with
  `try?` at every call site (`CursorOverlay.swift:169`, `App.swift:142`). We are free
  to establish the convention, and `SPEC.md:389` already dictates it:
  *"No `throws` without a concrete error enum."*
- **No `Tests/` directory, no `.testTarget`.** `swift test` finds nothing. Every
  `swift test --filter X` in the docs is aspirational.
- **No `Sources/Probe/`.** Every `swift run Probe ...` command in `SPEC.md:206-211`
  and throughout `build-sequence.md` is unrunnable. `build-sequence.md:112` is honest
  about this: task 1.1 is marked done while its own acceptance criterion
  ("Three targets") is unmet.
- **No `Safety/`.** `build-sequence.md:137-138` says the irreversibility classifier
  must exist *before the engine*.

Everything in `Sources/OpenAgent` is `@MainActor`-bound (`CursorOverlay.swift:19`,
`OverlayState` at `CursorView.swift:26`, `CursorDemo:132`, the launch `Task` at
`App.swift:20`). There are no actors, no `DispatchQueue`, no detached tasks.
**This is the single most important structural fact for this plan:** a `@MainActor`
network client would serialize every HTTP round trip behind the HUD's animation
sleeps. The client must be an `actor`, not main-actor-bound.

---

## 2. What the Jev API offers vs. what this project needs

Official docs are reachable: `https://docs.typesafe.ai/introduction` → HTTP 200,
no redirects, Mintlify-hosted, ~100 pages indexed at `/llms.txt`. Mintlify serves
`.md` source at `<page>.md`, so everything below is quoted from source.

### 2.1 The entire HTTP surface is two endpoints

```
POST https://api.typesafe.ai/v1/systemone    the only call that matters
GET  https://api.typesafe.ai/v1/models       returns aliases
```

**No pagination. No webhooks. No streaming. No batch/async job endpoint. No API
changelog.** (Only per-SDK changelogs exist.) This is a simplification, and it
should be written down so nobody designs around machinery that isn't there.

### 2.2 The fit is unusually good

```
                 WHAT JEV OFFERS                    WHAT THE HARNESS NEEDS
                 ───────────────                    ──────────────────────
  one request ─┬─ N questions                  ┌─── "which element do I click?"   (choice)
               │  against ONE shared state     ├─── "did the last step work?"     (noul)
               │  evaluated in PARALLEL        ├─── "how risky is this?"          (score)
               │  latency FLAT 1→25 questions  └─── "am I in the wrong context?"  (noul)
               │
               └─ therefore: verification is FREE if it rides in the selection call
```

`docs/harness.md:64-69` states the thesis: *"verification and selection ride in the
same Jev request... A design that verifies in a separate call pays twice for nothing."*
The API is shaped for exactly this. The batching is not a workaround; it is the
product.

### 2.3 Primitives, verbatim from `https://docs.typesafe.ai/api`

| Type | Question fields | Answer fields | Caps |
|---|---|---|---|
| `noul` | `instructions`, optional `criteria: {true,false}` | `type`, `noul` (0–1) — **no `confidence`** | — |
| `choice` | `instructions`, `criteria: map<option, …>` required | `type`, `choice`, `probabilities`, `confidence` | **max 255 options** |
| `score` | `instructions`, `criteria: ordered array` | `type`, `score` (float), `legend`, `probabilities`, `confidence` | **2–10 levels** |

Both caps are **officially documented**, not measured. `docs/jev-api-reference.md`
tags them `[M]`; they should be `[D]`. `Constants.Jev.maxCandidates = 255` and
`maxScoreLevels = 10` already match.

Question map keys: *"The key is not sent to the underlying model and is not used in
inference."* Free to use for our own correlation.

### 2.4 Budgets, price, limits

| | Value | Source |
|---|---|---|
| Context | **64k tokens total; 32k for `state` + longest question** | `/models` |
| Price | **$0.042/Mtok input, output free** | `/models` |
| Rate | **250,000 tok/s, 1,200 req/min** → `429` | `/models` |
| Timeout (SDK default) | 10.0s | `/sdk/python/api/constants` |
| Retries (SDK default) | `max_retries=2, backoff_initial=0.5, backoff_max=5.0, jitter=0.25, respect_retry_after=True` | `/sdk/python/api/retries` |
| Retryable statuses (SDK) | `{408, 429, 500–599}` | same |

The vendor warns the limits *"can change without notice while we do, as upcoming
large GPU deals land and we let in more users."* Do not hard-code assumptions about
headroom.

**Cost is not a binding constraint.** A step sending ~4,000 input tokens costs
~$0.000168. Forty steps ≈ **$0.0067** against `Constants.Budget.maxDollars = 0.25`
— about 37x headroom. The binding constraints are `maxSteps = 40` and
`maxMachineTime = 90s`. See §6.1, which is a real finding.

### 2.5 There is no Swift SDK

`docs/jev-api-reference.md:886` — `Swift | — | none | hand-roll the HTTP client`.
Confirmed against the vendor's SDK pages: Python and JavaScript only.

This matters more than it looks. **`TYPESAFE_API_KEY` is a Python/JS SDK behavior**
(`docs/jev-api-reference.md:895` — `with TypeSafeClient() as client:  # reads TYPESAFE_API_KEY`).
Swift inherits the *naming convention*, not the *mechanism*. We write the env read
ourselves.

Second consequence, and it is a live trap: `https://docs.typesafe.ai/primitives/score`
notes *"The SDK keys `probabilities` and `legend` by integer level rather than by
string."* **The HTTP API returns string keys. The Python SDK re-keys them.** Anyone
copying a Python example into a Swift `Codable` will write `[Int: Double]` and it
will not decode. This deserves a comment at the decode site.

### 2.6 Where the gaps are

| Need | Status |
|---|---|
| Batched selection + verification + risk | **Fits natively.** This is what the API is. |
| ≤255 candidates | Fits; `CandidateFilter` must enforce before the call, not after |
| Pinned model `jev-1.13.0` | Supported. Docs push `jev-latest`; `docs/host-contract.md:195` correctly says **never** use it |
| Warm connection (383ms vs ~900ms cold) | Achievable with one long-lived `URLSession`; **unverified by us** |
| `x-typesafe-request-id` logged | Official. Only support handle. |
| Margin guard `p[0]-p[1]` | **Our invention, better than the vendor's.** See §2.7 |
| `state` token cost of 255 candidates | **UNMEASURED.** See §7.1 |

### 2.7 One place this project is ahead of its vendor

Confidence is published — the exact function is in the `ConfidenceExplorer`
component source on `https://docs.typesafe.ai/confidence`:

```js
return Math.max(0, Math.min(1, (count * peak - 1) / (count - 1)));
```

This matches `docs/jev-api-reference.md:346` exactly. It reads **only `p_max`**, so
it is blind to where the runner-up sits. Three options at `{0.50, 0.49, 0.01}` and
`{0.50, 0.25, 0.25}` produce identical confidence and completely different
decisions.

`docs/jev-questions.md:184` guards on the margin `p[0] - p[1]` against
`Constants.Jev.selectionMargin = 0.25` **in addition to** confidence. The vendor
gates on confidence alone. **Keep the margin guard.** It is the better design and
it should be called out in code as a deliberate divergence, not silently inherited.

Corroborating this: the repo correctly observes that TypeSafe's own published
confidence thresholds contradict each other across three pages — `0.5/0.9` on
`/confidence`, `0.6/0.85` on `/patterns/confidence-routing` (same worked example),
`0.8` and `0.75` on `/concepts/how-to-build-with-system-one`. Verified. Do not
inherit a vendor threshold; derive our own and put it in `Constants.swift`.

---

## 3. Documentation defects found

The audit compared `docs/jev-api-reference.md` against the live docs. Structure is
~90% accurate and the `[M]/[D]/[3P]/[C]` provenance tagging is what made the audit
possible at all. The failures cluster in `[D]`-tagged items that were never
re-checked.

### 3.1 CRITICAL — a fabricated legal clause

`docs/jev-api-reference.md:993-994` claims:

> *"TypeSafe's Master Customer Agreement §2.3(f) prohibits customers from
> 'publish[ing] benchmarks or performance information about the Services.'"*

**Actual §2.3(f)** at `https://typesafe.ai/legal/mca`:

> *"(f) interfere with the operation of the Services;"*

The strings "benchmark" and "performance information" appear **zero times** in the
full MCA, fetched complete through §16.14. The repo builds a paragraph of argument
on this ("If you build on this, you have agreed not to say how it performed"), and
tags it `[M]` — verified — which makes it worse than an unsourced guess.

This is not a stale number. It is a quote of text that does not exist, attributed to
a legal document, constraining what this project believes it may publish.

**RESOLVED 2026-09-20 (D3) — fixed.** `docs/jev-api-reference.md:993` now quotes the
real §2.3(f), is re-tagged `[D]` with the source URL and a fetch date, and carries an
inline correction block recording what the previous revision claimed and why it was
wrong. The block quotes the fabricated text deliberately, so the error stays legible
rather than silently vanishing — the same pattern ADR 0002 and ADR 0005 use for their
own corrections. **Nothing in this project's licence terms restricts publishing
measurements.**

### 3.2 Fabricated quotations (2)

- `:237` — *"reliably up to roughly 240"* attributed to TypeSafe `[D]`. The string
  "240" does not appear on `/primitives/choice` or `/primitives`. The page says only
  *"up to 255 options, and adding options costs a few tokens each."* No reliability
  qualifier exists anywhere.
- `:201` — *"A value of 0.5 does not mean medium"* presented in quote marks as `[D]`.
  Not present. `/primitives/noul` says *"A value near 0.5 means the model gives yes
  and no similar probability."* **The substance is right; the quotation is
  manufactured.** Re-tag as paraphrase.

### 3.3 Stale numeric examples (4)

Every one of the vendor's worked numbers has drifted. These *could* be explained by
the docs changing since 2026-09-18 (the file's mtime), unlike §3.1/§3.2.

| Line | Repo says | Official says |
|---|---|---|
| `:279` | `0×0.0 + 1×0.70 + 2×0.30 = 1.30` | `0 x 0.0 + 1 x 0.57 + 2 x 0.43 = 1.43` |
| `:298` | score 0.57, confidence 0.35 | score 0.55, confidence 0.33 |
| `:310-313` | `1.30/0.54`, `1.07/0.90`, `1.28/0.57` | `1.43/0.35`, `1.03/0.96`, `1.43/0.35` |
| `:132` | quickstart `billing 0.84 / conf 0.596` | `technical`, conf `0.78`, `{technical:0.85, billing:0.15}` |

Qualitative conclusions survive in every case. The numbers do not.

### 3.4 Smaller corrections

- `:342` claims TypeSafe *"deliberately does not publish the formula"* for confidence.
  It is published, in the confidence page's component source. What is withheld is the
  *rationale*, not the formula.
- `:517` error table omits `403`, `404`, `408`. Conversely the **vendor's own table
  omits `400`** and the repo correctly includes it — `/sdk/python/api/exceptions` is
  the more complete error contract than `/api`. Worth a note.
- 255-option and 2–10-level caps tagged `[M]`; they are `[D]`.

### 3.5 Contradictions internal to the repo (11 found; 5 that would bite an implementer)

| # | Conflict | Live version |
|---|---|---|
| a | `classify` takes **two** inputs (`SPEC.md:359-372`) vs **five** (`harness.md:463-484`, `build-sequence.md:128-130`) | **Five.** SPEC's sample is pre-ADR-0007/0008 and is exactly what a reader of the style section would copy. |
| b | `element-sources.md:271` *"Never use `AXWindows.first`"* vs `:333-334` which does exactly that in a code sample | The prohibition. The file has two `§2.2` and two `§2.3`. |
| c | Two AX measurement tables disagree (`:307-313` Finder 909/116/91 vs `:370-376` Finder 174/33) | **909/116/91** — `build-sequence.md:213-214` uses them as acceptance criteria. |
| d | `Element` has 6 fields (`harness.md:252-259`) vs 8 (`element-sources.md:555-566`). `harness.md`'s own `classify` at `:474,478` reads `visionLabel`/`submitLabel`, fields its own `Element` lacks | **8 fields.** |
| e | `candidates` keyed `e17` (`SPEC.md:236`, `harness.md:342-347`) vs `"1"`,`"2"` (`SPEC.md:251`, `host-contract.md:78`) | **RESOLVED (D4): `e`-prefixed.** `SPEC.md:251` and `host-contract.md:78` must change to `{"e1": "New mail"}`. |

Also: ADR 0006 still specifies Apple Foundation Models for the v1 reference task
(`0006:55-58`) with a bare "Accepted" status, though ADR 0009 removed it
(`0009:112-113`) and `SPEC.md:603-605` marks it closed. 0004 and 0005 got supersession
annotations; 0006 did not.

**None of these block the Jev client.** All of them block the code that calls it.
Listed here so they are fixed at the source rather than rediscovered five times.

---

## 4. Proposed integration design

### 4.1 Placement

`Sources/Harness/Judgment/`, in the `Harness` target.

Two independent lines of evidence agree. `docs/build-sequence.md:156` specifies the
path. And the dependency direction forces it: `Package.swift:12` declares `Harness`
as *"Everything headless. No AppKit, no SwiftUI, no UI of any kind"*, and the only
target edge is `OpenAgent → Harness` (`Package.swift:16`). A client placed in
`OpenAgent` would be unreachable from any future headless code — including `Probe`.

### 4.2 Module shape

```
Sources/Harness/Judgment/
├── JevClient.swift        actor. one URLSession. transport only.
├── JevTypes.swift         Codable request/response. no behavior.
├── JevError.swift         typed, exhaustive, with isRetryable
├── Credentials.swift      env read, fail-fast
└── RetryPolicy.swift      backoff arithmetic, pure, testable

Sources/Probe/
├── main.swift             subcommand dispatch
├── JevLatency.swift       warm-vs-cold measurement
└── CaptureFixtures.swift  writes Tests/Fixtures/*.json from live responses

Tests/HarnessTests/
├── JevTypesTests.swift    decode every primitive from captured fixtures
├── JevErrorTests.swift    status → error, and retryability
├── RetryPolicyTests.swift backoff, jitter bounds, budget clamp
└── CredentialsTests.swift present / absent / empty
```

### 4.3 The one hard boundary

`SPEC.md:354-356`: *"judgment and policy never mix. A model result is read, then a
named constant decides what happens."*

```
  JevClient                          call site (Loop / Safety)
  ─────────                          ────────────────────────
  returns raw Double                 applies Constants.Jev.selectionConfidence
  probabilities, verbatim     ──►    applies Constants.Jev.selectionMargin
  NEVER thresholds                   decides
  NEVER decides                      logs the decision
```

**`JevClient` must not import `Constants` for any threshold.** It may read
`Constants.Jev.requestTimeout` and the retry knobs, because those are transport
policy, not judgment. Anything that turns a probability into a verdict lives at the
call site. This is the rule that keeps `Constants.swift` reviewable as the one file
a human reads to understand behavior (`Constants.swift:3-15`).

### 4.4 Concurrency

```swift
public actor JevClient {
    private let session: URLSession      // created once, held for the process
    private let apiKey: String
    private let model: String            // Constants.Models.jev — pinned
}
```

`actor`, explicitly **not** `@MainActor`. Everything in `OpenAgent` is main-actor
bound; a main-actor client would serialize network I/O behind HUD animation sleeps
(`Constants.HUD.pressSeconds`, `minMoveSeconds`, etc.).

The warm connection (`docs/harness.md:611-614`: 383ms warm vs ~900ms cold, TLS+TCP
to their edge ~520ms from this location) comes from **reusing one `URLSession`
instance**, which pools connections per host. Creating a session per call throws the
383ms away. `docs/host-contract.md:204-206` is clear that the warmth dies between
`run`/`resume` invocations since those are separate processes — the first call after
a resume pays cold. We cannot fix that; we should log it so the latency data is
interpretable.

### 4.5 Types

`state` is documented as `string | object | array`. **We will type it as one concrete
`Encodable` struct, not a three-way union.** `docs/harness.md:330-333` says keep
state minimal and resist growing it — the vendor calls the failure mode context rot.
We only ever send an object. Building a union for two cases we will never use is
speculative generality.

Questions are heterogeneous → `enum Question` with associated values and a hand-written
`Encodable`. Answers are heterogeneous → `enum Answer` with `Decodable` keyed on the
`type` discriminator, with an explicit `default:` that throws
`JevError.malformedResponse(field:)` rather than silently dropping an unknown type.

```swift
public enum Answer: Sendable {
    case noul(value: Double)                                  // no confidence field
    case choice(choice: String, probabilities: [String: Double], confidence: Double)
    case score(score: Double, legend: [String: String],        // STRING keys — see §2.5
               probabilities: [String: Double], confidence: Double)
}
```

Note `[String: Double]`, not `[Int: Double]`. The Python SDK re-keys by integer; the
wire does not. Comment this at the decode site — it is the most likely single bug in
the whole integration.

### 4.6 Error handling

`SPEC.md:389`: *"Errors are typed and exhaustive. No `throws` without a concrete
error enum."* There is no existing convention to match, so this establishes it.

```swift
public enum JevError: Error, Equatable, Sendable {
    case unauthorized                            // 401 — NEVER retry
    case badRequest(detail: String)              // 400 — our bug
    case forbidden                               // 403
    case notFound                                // 404
    case unprocessable(detail: String)           // 422 — our bug
    case rateLimited(retryAfter: Duration?)      // 429 — retry, honor header
    case overloaded                              // 529 — retry
    case server(status: Int)                     // 5xx — retry
    case timedOut                                // 408 + URLError.timedOut — retry
    case transport(code: URLError.Code)          // retry
    case malformedResponse(field: String)        // NEVER retry
    case modelMismatch(requested: String, returned: String)   // never retry; see below

    public var isRetryable: Bool { ... }
}
```

Retryable: `408, 429, 5xx, 529`, transport. Not retryable: `400, 401, 403, 404, 422`,
malformed. This matches the vendor SDK's `{408, 429, range(500,600)}` plus `529`.

`modelMismatch`: `docs/host-contract.md:196` requires recording `response.model` on
every `Step`. If we pin `jev-1.13.0` and the response says otherwise, that is a
silent behavioral change in a system whose thresholds were calibrated against a
specific model. **Recommendation: log loudly and continue** — failing the step on a
vendor-side alias change would take the agent down mid-task for something that is
probably fine. But it must be visible, not swallowed.

Every response, success or failure, logs `x-typesafe-request-id`
(`docs/jev-api-reference.md:107`, `docs/host-contract.md:199`,
`docs/build-sequence.md:157`). It is the only support handle.

**Redaction is ours to own.** `docs/jev-api-reference.md:921-922` warns that at
`debug` level the vendor SDKs redact secret *headers* but **not** bodies. Hand-rolling
means no redaction exists unless we write it. The `Authorization` header must never
reach a log.

### 4.7 Configuration

New constants required in `Constants.Jev` (the "no magic numbers" rule at
`Constants.swift:3-15` leaves no alternative):

```swift
static let baseURL          = URL(string: "https://api.typesafe.ai")!
static let maxRetries       = 2          // [D] vendor SDK default
static let backoffInitial   = Duration.milliseconds(500)
static let backoffMax       = Duration.seconds(5)
static let backoffJitter    = 0.25
```

All four tagged `[D]` with the vendor URL, matching the file's existing provenance
discipline.

Credentials do **not** go in `Constants.swift`. That file is the one a human reviews
for thresholds (`Constants.swift:5-7`); a secret-shaped runtime lookup in it dilutes
that and invites someone to paste a literal key into the most-read file in the repo.
`Credentials.swift` owns it:

```swift
enum Credentials {
    static func apiKey() throws -> String   // reads TYPESAFE_API_KEY, fails fast
}
```

Fail with a message that names the variable. **Never `?? ""`** — an empty key produces
a `401` you then diagnose against `docs/jev-api-reference.md:518`, instead of a
message that tells you what to export.

**DECIDED (D1): direnv / shell wrapper. No `.env` parser.** Swift has no native `.env` support,
and a hand-rolled one is ~15 lines of the parts people get wrong (`export ` prefix,
`#` inside quoted values, CRLF, escapes). Bridge outside Swift instead: `direnv` with
`dotenv`, or `set -a; source .env; set +a` in a wrapper. Every documented invocation
in this project is `swift run` from a terminal (`SPEC.md:187-210`, ~20 `swift run Probe`
lines in `build-sequence.md`), which inherits the shell environment for free. Zero
parser code, zero new test surface.

**Known future break, do not build for it now:** a Finder-launched `.app` does not
inherit the shell environment — `launchd` never sourced `~/.zshrc`, so
`ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]` returns `nil`. Nothing
bundles an `.app` today (no `Info.plist`, no `codesign`, no entitlements anywhere in
the repo; `App.swift:18` gets accessory status at runtime via
`setActivationPolicy(.accessory)`). But two forces push there: `App.swift:5-13` is
already a SwiftUI `App` with `@NSApplicationDelegateAdaptor`, and
`docs/element-sources.md:429` notes Screen Recording TCC has no `Info.plist` key —
TCC grants bind to code identity, and an ad-hoc-signed binary gets re-signed every
rebuild, so approvals evaporate constantly. That pain drives people to a signed
bundle. **Structure the accessor as `env → (later) Keychain` so adding the second
source is a one-line change.** Not `UserDefaults` — that is a world-readable plist in
`~/Library/Preferences`, i.e. a plaintext secret with extra steps.

### 4.8 Request flow

```
  Loop (caller)
      │
      │  state: StepState (minimal — resist growth, context rot)
      │  questions: [String: Question]   ≤255 options on any choice
      ▼
  ┌─────────────────────────────────────────────────────────┐
  │ JevClient.evaluate(state:questions:)          [actor]   │
  │                                                         │
  │  1. Credentials.apiKey()        ──► throws unauthorized │
  │  2. encode JevRequest           ──► throws malformed    │
  │  3. POST /v1/systemone                                  │
  │       Authorization: Bearer ***                         │
  │       timeout: Constants.Jev.requestTimeout (10s)       │
  │  4. log x-typesafe-request-id   ALWAYS, both paths      │
  │  5. map status ──► JevError                             │
  │  6. if isRetryable && budget remains ──► backoff, goto 3│
  │  7. decode answers              ──► throws malformed    │
  │  8. if response.model != pinned ──► log modelMismatch   │
  └─────────────────────────────────────────────────────────┘
      │
      │  [String: Answer]  — raw probabilities, NO thresholds applied
      ▼
  Call site applies Constants.Jev.selectionConfidence / .selectionMargin
```

---

## 5. Test plan

There is no test infrastructure. This plan establishes it. Per `SPEC.md:394-436` the
framework is **swift-testing**, not XCTest, in four levels — Unit and Fixture inside
`swift test`, Battery eval and Live probe as `Probe` subcommands, because
`SPEC.md:409` observes *"a test suite that needs an API key and a browser is a test
suite people stop running."*

### 5.1 The fixture bootstrap order

There is a chicken-and-egg problem worth naming. `build-sequence.md` requires fixtures
(0.3) before the client is tested (1.4) — but capturing real fixtures requires a
working client. Resolution:

```
  minimal client (no retry, no polish)
        │
        ▼
  Probe capture-fixtures  ──► writes Tests/Fixtures/*.json from LIVE responses
        │
        ▼
  full test suite runs offline against those fixtures, forever after
        │
        ▼
  harden client (retry, errors, redaction) against the suite
```

Fixtures are captured once, committed, and the suite never needs a key again.
Check `.gitignore:7-10` before committing them — it already guards screenshot/DOM
fixtures that could carry session tokens. Jev fixtures carry element labels, which
can include personal content. **Scrub before commit.**

### 5.2 Coverage diagram

```
CODE PATH COVERAGE  (all GAP — nothing exists yet)
==================================================
[+] Judgment/JevClient.swift
    │
    └── evaluate(state:questions:)
        ├── [GAP] 200 happy path, all three primitives     — fixture
        ├── [GAP] 401 unauthorized, NOT retried            — fixture  CRITICAL
        ├── [GAP] 429 + retry-after honored, then 200      — fixture
        ├── [GAP] 429 retries exhausted → rateLimited      — fixture
        ├── [GAP] 529 overloaded → retried                 — fixture
        ├── [GAP] 5xx → retried                            — fixture
        ├── [GAP] 400 / 422 → NOT retried                  — fixture
        ├── [GAP] 408 / URLError.timedOut → retried        — fixture
        ├── [GAP] malformed JSON → malformedResponse       — fixture
        ├── [GAP] unknown answer `type` → throws, not drop — fixture  CRITICAL
        └── [GAP] response.model != pinned → logged        — fixture

[+] Judgment/JevTypes.swift
    ├── [GAP] noul decode — asserts NO confidence field
    ├── [GAP] choice decode — probabilities sum ≈ 1.0
    ├── [GAP] score decode — STRING-keyed probs + legend   CRITICAL (§2.5 trap)
    ├── [GAP] choice encode with exactly 255 options
    └── [GAP] score encode rejects <2 and >10 levels

[+] Judgment/RetryPolicy.swift
    ├── [GAP] backoff sequence 0.5 → 1.0, clamped at 5.0
    ├── [GAP] jitter stays within ±0.25 band
    └── [GAP] total elapsed clamped by stepTimeout          CRITICAL (§6.1)

[+] Judgment/Credentials.swift
    ├── [GAP] present → returns value
    ├── [GAP] absent → throws, message NAMES the variable
    └── [GAP] empty string → treated as absent, not as a key

LIVE PROBE  (Probe target — never in `swift test`)
==================================================
    ├── [GAP] [→PROBE] jev-latency: warm vs cold, confirm 383 / ~900ms
    ├── [GAP] [→PROBE] jev-budget: token cost of a 255-candidate state  (§7.1)
    └── [GAP] [→PROBE] battery-eval: 5× repeat, straddle gate

──────────────────────────────────────────
COVERAGE: 0/25 paths (0%) — no test target exists
GAPS: 25 (22 unit/fixture, 3 live probe)
CRITICAL: 4
──────────────────────────────────────────
```

### 5.3 The straddle gate

`SPEC.md:431-434`: a question whose answers straddle its threshold across 5 repeats
is a **failing question, regardless of mean accuracy**. `build-sequence.md:177-179`
adds: *"the fix is to reword the question or move the threshold, never to nudge the
threshold to make the suite pass."*

Worth knowing: **this criterion is the repo's own invention and is stricter than
anything the vendor publishes.** Official guidance is only *"Test thresholds by
plotting confidence against accuracy on your data"*
(`/concepts/how-to-build-with-system-one`). Given the vendor documents ±5pp
non-determinism as a jagged edge, a stricter gate is defensible. Keep it, but know
it is ours.

---

## 6. Failure modes

### 6.1 FINDING — retry budget can exceed the step timeout

`[P1] (confidence: 9/10)` — arithmetic on documented constants.

```
Constants.Jev.requestTimeout   = 10s     (Constants.swift:142)
Constants.Budget.stepTimeout   = 20s     (Constants.swift:253)
vendor SDK retry default       = 2 retries, backoff 0.5 → 1.0

worst case:  10s + 0.5s + 10s + 1.0s + 10s  =  31.5s
                                                  ^^^^^
                                          exceeds stepTimeout by 57%
```

A step that exhausts its retries blows its own deadline before the retry policy
finishes. **The retry loop must be clamped by the remaining step budget, not run
independently.** Concretely: `RetryPolicy` takes a deadline and stops issuing
attempts that cannot complete before it.

If this is not fixed, the failure is silent and confusing — the step is killed
mid-retry and the log shows a timeout, not a rate limit, so the real cause
(`429`) never surfaces.

**DECIDED (D2): clamp to the deadline.** `RetryPolicy.attempt(deadline:)` refuses to
start an attempt that cannot finish before the step deadline, and surfaces
`rateLimited` rather than a timeout. `Constants.Jev.maxRetries` stays at the vendor
default of 2 and `Constants.Budget.stepTimeout` stays at 20s — neither constant moves
to accommodate the other.

### 6.2 FINDING — `maxMachineTime` has no worst-case headroom

`[P2] (confidence: 7/10)` — assumes per-step costs compose additively and that all 40
steps act.

```
per acting step, worst case:
    perception  552ms   (tier 1 BiDi, SPEC.md:92-98)
  + Jev          383ms   (warm; ~900ms on the first call after resume)
  + HUD          990ms   (Constants.HUD.worstCaseOverheadSeconds)
  ─────────────────────
                1,925ms

40 steps × 1.925s              =  77.0s
+ 3 escalations × 4.8s (tier 4) =  14.4s
                                  ──────
                                   91.4s   >  maxMachineTime 90s
```

Typical case is ~58s and fine. But the budget has **zero worst-case headroom**, which
means any latency regression in perception turns into task failure rather than
degraded performance. Not a blocker for the Jev client. Flagged so it is a known
number rather than a surprise. Cheapest fix is raising `maxMachineTime`; the honest
fix is measuring real per-step cost once the loop exists.

### 6.3 Silent-failure audit

| Failure | Test? | Handled? | User sees? |
|---|---|---|---|
| Missing `TYPESAFE_API_KEY` | planned | fail-fast, names the var | clear message |
| Key present but wrong | planned | `401`, not retried | clear message |
| `429` sustained | planned | retry then surface | clear, **if** §6.1 fixed |
| Unknown answer `type` | planned | throws | clear |
| `response.model` drift | planned | logged, continues | **log only** — accepted |
| **`Authorization` in a debug log** | **none** | **none** | **silent — CRITICAL GAP** |
| `state` exceeds 32k tokens | **none** | **none** | **`422`, cause unclear — GAP** |

**Two critical gaps**, both cheap:
1. Header redaction has no test and no implementation. The vendor SDKs do this for
   you; we hand-roll, so we get nothing for free (§4.6).
2. Nothing checks the 32k `state` budget before sending. It surfaces as a `422` whose
   message may not say "too long." A pre-flight estimate is a few lines.

---

## 7. Open questions

**7.1 — ~~What does a 255-candidate `state` cost in tokens?~~ MEASURED 2026-09-20.**

`Probe jev-budget --browser`, real GitHub page, live Jev call:

| | |
|---|---|
| candidates | 60 |
| state bytes | 4,320 |
| **actual input tokens** | **3,608** |
| per candidate | **60.1 tokens** |
| extrapolated to 255 | **~15,300** |
| ceiling | 32,000 |

**`maxCandidates = 255` is reachable, with roughly 2x headroom.** The per-candidate
cost is high because every candidate appears twice in the state — once in
`screen_now`, once in `candidates` — and short labels with heavy JSON punctuation
tokenise far worse than prose.

**It also found a bug.** The preflight's 4-characters-per-token heuristic estimated
1,080 tokens where the truth was 3,608 — understating by **3.34x**, in the one
direction that matters. A state genuinely over 32k would have been estimated under
10k, passed the preflight, and failed at the API as a `422` that need not mention
length. Corrected to 1 character per token, which errs high. `StatePreflightTests`
pins it to the measurement.

**7.2 — What is the exact variable name in `.env`?** Permission-blocked three times.
Needs a human. See §0.1.

**7.3 — Does the API accept a raw key without the `Bearer ` prefix?** Undocumented.
Do not rely on either behavior; always send `Bearer `.

**7.4 — `TYPESAFE_BASE_URL` trailing-slash convention?** Undocumented. Normalize
ours before joining paths.

**7.5 — Are rate-limit headers exposed?** `docs/jev-api-reference.md` claims `[M]`
that none are. Unverifiable from documentation. If true, we cannot pre-emptively
throttle and can only react to `429`.

**7.6 — ~~`candidates` key namespace~~ RESOLVED (D4): `e`-prefixed.** `e0`, `e1`, `e17`.
Rationale: tier-4 mark indices and score levels are both small integers, so bare
integer candidate IDs would put three distinct namespaces in one integer space.
`SPEC.md:251` and `host-contract.md:78` need updating — added to Lane B as **F6**.

**7.7 — ~~Doc defect timing~~ RESOLVED (D3).** MCA claim fixed now; F2–F6 batched in
Lane B.

**7.8 — ~~Unverifiable `[M]` claims.~~ Latency CONFIRMED 2026-09-20.**

`Probe jev-latency`, five live calls:

```
cold 1119 ms · warm mean 408 ms
  1119 / 397 / 413 / 394 / 430
```

The claim was 383 ms warm and ~900 ms cold. **Warm lands within 7%**, so the
per-step latency budget in `Constants` holds on this network. Cold is 24% slower
than documented, which is location-dependent and only matters for the first call
after a resume — `docs/host-contract.md` §6 already says to budget for it.

`response.model` echoed `jev-1.13.0` on all five, so the pin holds and no alias
has drifted.

Still unverified: the ~270-token fixed overhead, the 8-run determinism spread, the
prompt-injection table, and the 120k/260k character probe. These need a fixture set,
not a key.

---

## 8. Implementation order

Each step names its verification. Nothing proceeds without it.

```
  PHASE A — make the project testable            (nothing Jev-specific)
  ────────────────────────────────────────────────────────────────────
  A1  Add .testTarget + Probe target to Package.swift
      verify: `swift build` succeeds, `swift test` runs 0 tests without error
      note: this finally satisfies build-sequence 1.1's real acceptance criterion

  A2  Fix Constants.swift:274 agentProfilePath  computer-agent → open-agent
      verify: grep finds zero `computer-agent` outside .build/
      why here: it is a one-line safety fix and the rename already broke it

  PHASE B — credentials                          (blocked on 7.2)
  ────────────────────────────────────────────────────────────────────
  B1  Credentials.swift — read TYPESAFE_API_KEY, fail fast, never `?? ""`   [D1]
      verify: CredentialsTests — present / absent / empty
  B2  .envrc with `dotenv`; NO Swift parser                              [D1]
      verify: `swift run Probe jev-latency` sees the key

  PHASE C — minimal client, enough to capture fixtures
  ────────────────────────────────────────────────────────────────────
  C1  JevTypes.swift — request + the three answer shapes
      verify: encodes a known-good request byte-for-byte against the docs example
  C2  JevClient.evaluate — happy path only, one URLSession, no retry
      verify: `Probe jev-latency` returns a real answer and prints request-id
  C3  Probe capture-fixtures → Tests/Fixtures/*.json
      verify: fixtures exist, are scrubbed of personal content, and are committed

  PHASE D — harden                               (offline from here)
  ────────────────────────────────────────────────────────────────────
  D1  JevError.swift + full status mapping
      verify: JevErrorTests, all 11 paths in §5.2
  D2  RetryPolicy.attempt(deadline:), CLAMPED      ◄── §6.1  [D2]
      verify: RetryPolicyTests incl. the stepTimeout clamp
  D3  Header redaction + a test that greps logs for the key
      verify: the log-scrape test fails if Authorization ever appears
  D4  Pre-flight state-size estimate               ◄── §6.3
      verify: oversized state throws locally, never round-trips to a 422

  PHASE E — measure                               (needs a key)
  ────────────────────────────────────────────────────────────────────
  E1  Probe jev-budget — answers 7.1
      verify: a real token number for a 255-candidate state
  E2  Probe jev-latency — warm vs cold, re-establish 383 / ~900ms
      verify: numbers land in docs with a fetch date

  PHASE F — doc repair                            (independent, any time)
  ────────────────────────────────────────────────────────────────────
  F1  ✅ DONE 2026-09-20 — MCA claim corrected + correction block  §3.1
  F2  Fabricated quotes :201, :237 → paraphrase
  F3  Refresh the four numeric examples, record a fetch date
  F4  Re-tag 255/2-10 caps [M] → [D]; add 403/404/408 to :517
  F5  Reconcile §3.5 a-d in the source docs
  F6  Apply D4: SPEC.md:251 + host-contract.md:78 → `{"e1": ...}`   [D4]
```

### Parallelization

| Lane | Steps | Touches | Depends on |
|---|---|---|---|
| **A** | A1 → A2 → B1 → C1 → C2 → C3 → D1 → D2 → D3 → D4 | `Package.swift`, `Sources/Harness/Judgment/`, `Tests/`, `Sources/Probe/` | — |
| **B** | ~~F1~~ → F2 → F3 → F4 → F5 → F6 | `docs/` only | — |
| **C** | B2 | tooling, `.envrc` | — |

**Lanes A, B and C share no files and can run in parallel worktrees.** Lane B (doc
repair) is pure prose and touches nothing Lane A compiles. Phase E joins Lane A after
C2 and needs a key, so it cannot run unattended.

Lane A is strictly sequential internally — each step's verification is the next
step's precondition.

---

## 9. NOT in scope

| Deferred | Why |
|---|---|
| `Safety/` classifier + label denylist | `build-sequence.md:137-138` requires it before anything that *acts*. The Jev client does not act. It is the next thing, not this thing. |
| `Perception/` — `BiDiSource`, `AXSource`, `CandidateFilter` | Produces the candidates the client sends. Independent of transport. ADR 0006 defers browser work off the v1 path entirely. |
| `Core/Loop` | Calls the client. Needs Safety first. |
| The question batteries themselves | `docs/jev-questions.md` has the wording; validating it is `Probe battery-eval`, which needs fixtures, which need Phase C. |
| Keychain credential storage | Strictly worse than env vars while unsigned — a rebuilt binary gets a fresh code identity every time, so ACL prompts would fire constantly. §4.7 leaves the seam. |
| `.env` parser in Swift | ~15 lines of edge cases to replace one line of `direnv`. §4.7. |
| Bundling a signed `.app` | Real and coming (TCC identity, `docs/element-sources.md:429`), but not on this path. |
| `ApprovalSheet.swift` | No approval mechanism exists, which is safe only because nothing can act yet. Ships with Execution. |
| Fixing ADR 0006's stale Foundation Models reference | One-line supersession note. Bundled into F5. |
| Deleting `OPENROUTER_API_KEY` from `.env` | Yours to do. I will not touch `.env`. |

## 10. What already exists and is reused, not rebuilt

| Exists | Used how |
|---|---|
| `Constants.Jev` — 14 values incl. `requestTimeout`, `maxCandidates`, `maxScoreLevels`, `selectionConfidence`, `selectionMargin` | Read directly. Only 5 transport constants added (§4.7). |
| `Constants.Models.jev = "jev-1.13.0"` | The pin. Not redefined. |
| `docs/jev-api-reference.md` | ~90% accurate. Corrected in place, not replaced. Its `[M]/[D]/[3P]/[C]` tagging is what made the audit possible — preserve it. |
| `docs/jev-questions.md` | The batteries. Consumed as-is by `Probe battery-eval`. |
| `Package.swift` two-target split | Extended with test + Probe targets. Boundary unchanged. |
| The margin guard `p[0]-p[1]` | Kept, and it is better than the vendor's own gate (§2.7). |

---

## Review summary

| | |
|---|---|
| Scope challenge | Reduced. Plan covers transport only; Safety/Perception/Loop explicitly deferred (§9). |
| Architecture | 2 findings (§6.1 P1, §6.2 P2) |
| Code quality | Convention established from scratch — no existing pattern to violate (§4.6) |
| Tests | Diagram produced, **25 gaps, 4 critical**, 0% coverage today |
| Performance | Warm-connection design (§4.4); budget headroom finding (§6.2) |
| Failure modes | **2 critical silent gaps**: header redaction, state-size preflight |
| Doc defects | **1 fabricated legal clause**, 2 fabricated quotes, 4 stale examples, 11 internal contradictions |
| Files touched | 12 new, 2 modified. Under the 8-file smell threshold for *modified*; new files are a new module, which is the point. |
| Parallelization | 3 lanes, 2 fully parallel |
