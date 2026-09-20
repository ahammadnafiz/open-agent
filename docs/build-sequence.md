# Build Sequence

Ordered by dependency, with risk pulled forward. Each task states what must be
true when it is done and the exact command that proves it.

**Native-first.** Tiers 2 and 4 ship before any browser work — see
[ADR 0006](./adr/0006-native-first-sequencing.md). Tier 2 measured 100% hit,
100% gated, 100% gate precision against tier 1's 81/69/100, needs no browser
lifecycle, and carries none of the X.com risk.

**Phase 0 is now one task.** The X.com question moved to the browser phase where
it belongs.

---

## Status — 2026-09-18

**Already measured and passing.** These were run as throwaway probes before any
harness code; the numbers are in SPEC.md § Success Criteria.

| | Result |
|---|---|
| S5 tier 1 (DOM), 16 intents / 4 real sites | **69% gated, 100% gate precision**, 81% raw |
| S5 tier 2 (AX), 16 intents / Finder + Settings | **100% gated, 100% gate precision**, 100% raw |
| **S5 blended, 32 intents** | **84% gated, 27/27 correct** — passes ≥60% |
| S6 latency | **552 ms** median fast path; Jev alone 468–552 ms |
| S7 candidate ≤255 | holds — 928→43, 227→127, 423→91, 336→26 |
| Tier 4 model A/B, 4 models × 12 intents | `gemini-3.8-flash` chosen — 83%, $0.00096 |
| BiDi on Zen | session, navigate, DOM extract all working |
| Vision OCR | 23–368 ms full Retina screen, on-device |

**Blocked, and why.**

- **X.com under BiDi** — unrun. **No longer a Phase 0 blocker**; it moved to the
  browser phase (ADR 0006) and gates only the tier-1 reference task.
- **Tier 3 honest hit rate** — cannot be measured until line splitting (task 3.4)
  exists, because merged observations make substring scoring meaningless.

**New work the measurements revealed** — tasks 3.4 and 3.5 below. Task 3.4 is the
highest-value item in the whole perception layer.

---

## Phase 0 — De-risk (before any harness code)

The cheapest possible answers to the two questions that could change the design.

### 0.1 Does X.com tolerate a BiDi-driven browser? — DEFERRED to the browser phase

*Not a blocker for v1 under ADR 0006. Kept here because it must be run before any
browser work starts.*


- **Acceptance:** A logged-in agent profile can navigate to a profile page, open
  the composer, and type into it under BiDi without triggering a challenge,
  rate-limit, or lock.
- **Verify:** Launch Zen on the agent profile, log into X **by hand once**, then
  drive navigate + click-compose + type via a throwaway BiDi script. Observe.
- **If it fails:** The reference task in SPEC.md § S1 changes site. X support
  becomes its own problem with its own spec. **This does not change the
  architecture** — only the demo. Knowing that now is worth an hour.
- **Files:** `Sources/Probe/` only. Nothing in `Harness/`.

> This is the single highest-risk item in the project and it is unresolved.
> X fingerprints automated browsers aggressively, and the headline task depends
> on it.

### 0.2 Can Electron apps be unlocked?

- **Acceptance:** A definite yes or no on whether setting `AXManualAccessibility`
  on an Electron *application* element (Cursor, Slack) produces a usable tree.
- **Verify:** `swift run Probe ax-unlock Cursor`. Measured baseline: Cursor and
  ghostty currently expose **no AX window at all**.
- **If no:** Electron and GPU-rendered apps are permanently vision-only. Record
  it in SPEC.md § Open Questions Q2 and move on — it is a scope fact, not a
  blocker.

### 0.3 Capture the fixture corpus

- **Acceptance:** ≥12 DOM snapshots and ≥6 AX snapshots covering the intended
  task surface, stored in `Tests/Fixtures/`, **scrubbed of session tokens**.
- **Verify:** `swift run Probe capture --url … --out Tests/Fixtures/dom/`, then
  `CandidateFilterTests` asserts every fixture reduces to ≤255.
- **Why first:** Every later task tests against these. Building the filter
  without them means tuning against imagination.

---

## Phase 1 — Foundations

Pure logic. No network, no UI, no browser. Fully unit-testable.

### 1.1 Package skeleton

- **Acceptance:** `swift build` succeeds. Three targets: `Harness` (library),
  `ComputerAgent` (app), `Probe` (executable). Zero external dependencies.
- **Verify:** `swift build -c release && swift test`
- **Files:** `Package.swift`

### 1.2 Core types

- **Acceptance:** `ActionKind`, `Action`, `ElementRef`, `Element`, `Plan`,
  `PlanStep`, `Step`, `StepVerdict`, `Budget` compile and round-trip through
  `Codable`. `ElementRef` has **no coordinate case**.
- **Verify:** `swift test --filter CoreTypesTests`
- **Files:** `Sources/Harness/Core/{Task,Action,Budget}.swift`

### 1.3 Safety classifier — *do this before anything that can act*

- **Acceptance:** `classify(_:target:)` returns `max(declared, byLabel)`. A test
  enumerates **every** `ActionKind` × a denylist-matching label and asserts the
  result is `.irreversible` in every case. A second test asserts no input can
  produce `.reversible` where either input said `.irreversible`.
- **Verify:** `swift test --filter SafetyTests` — must be 100% branch coverage.
- **Files:** `Sources/Harness/Safety/{Irreversibility,LabelDenylist}.swift`
- **Why here:** Nothing that executes an action may exist before the thing that
  gates it. Build the brake before the engine.

### 1.4 Candidate filter

- **Acceptance:** Reduces any fixture to ≤255 while preserving every element that
  is rendered, on-screen, and labelled. **Raises `.tooManyCandidates` rather than
  truncating** — silent truncation removes the correct answer with nobody noticing.
- **Verify:** `swift test --filter CandidateFilterTests`. Must reproduce the
  measured reductions: Wikipedia 913→42, HN 227→127, GitHub 217→44.
- **Files:** `Sources/Harness/Perception/CandidateFilter.swift`

---

## Phase 2 — Judgment

### 2.1 Jev client

- **Acceptance:** One warm `URLSession` for the process lifetime. Sends a batched
  request, decodes `noul` / `choice` / `score` answers, retries 429 and 529 with
  backoff, records `x-typesafe-request-id` and `response.model`.
- **Verify:** `swift run Probe jev-latency` — expect **p50 ≤ 700 ms** end to end
  from this machine (~250 ms of that is network round trip).
- **Files:** `Sources/Harness/Judgment/JevClient.swift`

### 2.2 The step battery

- **Acceptance:** Questions match [jev-questions.md](./jev-questions.md) **verbatim**.
  `StepVerdict` carries raw probabilities only — no field on it is a `Bool`.
- **Verify:** `swift run Probe battery-eval`. Reproduce the measured baseline:
  17/18 on the verification fixtures, 412 ms for the full battery.
- **Files:** `Sources/Harness/Judgment/{Batteries,StepVerdict}.swift`

### 2.3 Eval harness

- **Acceptance:** Runs every fixture **5×**, reports mean, σ, and whether any
  question **straddles its threshold** across repeats.
- **Verify:** `swift run Probe battery-eval` exits non-zero if any question
  straddles. *Straddling fails the suite even at 100% mean accuracy — the fix is
  to reword the question or move the threshold, never to nudge the threshold to
  make the suite pass.*
- **Files:** `Sources/Probe/BatteryEval.swift`

---

## Phase 3 — Perception

### 3.1 BiDi client — *browser phase, after v1 ships*

- **Acceptance:** `session.new` → `browsingContext.getTree` →
  `browsingContext.navigate(wait: "complete")` → `script.evaluate` all work
  against a launched Zen. Frames without an `id` route to an event stream, not
  the pending table.
- **Verify:** `swift run Probe bidi-dom https://en.wikipedia.org/wiki/Accessibility`
  → expect ~3,684 DOM nodes, ~600 actionable, **42 after filtering**.
- **Files:** `Sources/Harness/Perception/BiDiSource.swift`
- **Gotchas, all hit during design:** `--no-remote` is mandatory; the port serves
  WebSocket only and has no `/json/version`; readiness is a connect-retry loop,
  not a sleep.

### 3.2 AX source — **FIRST perception task under native-first**

- **Acceptance:** Activates the app, reads `kAXRoleAttribute` on the application
  element, attempts the Electron unlock, then resolves the window by
  **`AXFocusedWindow` → `AXMainWindow` → largest by area**, retrying on empty.
  Reads labels as `AXTitle ?? AXDescription ?? AXHelp ?? AXValue`.
- **Verify:** `swift run Probe ax-tree Finder` → expect **909 nodes, 116
  pressable, 91 labelled (78%)** with a Finder browser window focused.
  `System Settings` → 161 / 23 / 16 (70%).
- **Files:** `Sources/Harness/Perception/AXSource.swift`
- **Two gotchas, both hit during design and both produced wrong conclusions:**
  - Walking `AXChildren` of the **app element** yields the **menu bar** — 10,804
    nodes for Zen, zero window content.
  - Taking `AXWindows.first` yields Finder's **desktop** — `AXGroup "desktop"`,
    2 nodes, no controls. This reads identically to an app being AX-blind. It is
    why Finder measured 2 nodes for most of this project and 909 once fixed.
- **Label fallback matters:** 77% of Zen's buttons have no `AXTitle`.

### 3.4 ~~OCR line splitting by gap~~ — ATTEMPTED, IMPOSSIBLE. Replaced by 3.4b.

**Do not build this.** Implemented and measured 2026-09-18; the approach cannot
work and the reason is informational, not a matter of tuning.

`VNRecognizedText.boundingBox(for:)` does return real per-word glyph boxes — a
control test with `iiii` (77 px) against `WWWW` (257 px) confirms they are
measured, not interpolated. The boxes are fine. **The gaps carry no signal.**

Measured on Wikipedia's `"Donate Create account Log in"`, which is three separate
links, at three capture resolutions:

| | Donate\|Create *(between links)* | Create·account *(within one link)* |
|---|---|---|
| DPR 1 — 1440×900 | 2 px | 2 px |
| DPR 2 — 2880×1800 | 3 px | 3 px |
| DPR 3 — 4320×2700 | 6 px | 5 px |

Inter-control and intra-control spacing are identical at every scale, because the
page renders its navigation at word spacing. Raising capture resolution scales
both equally.

Vision already performs the only spatial split available to it: given 80 px gaps
it emits separate observations. When it merges, the text really is adjacent.

### 3.4b Assign OCR text to detector boxes — *replaces 3.4*

- **Acceptance:** The ANE element detector supplies true control boxes; each OCR
  string is assigned to the box it falls inside. A control's label is the text
  within its own box, so `"Donate Create account Log in"` resolves to three
  candidates because the *detector* saw three controls.
- **Verify:** rerun the tier-3 measurement; the honest hit rate should rise from
  ~46%, and no candidate should span two detector boxes.
- **Files:** `Sources/Harness/Perception/{IconDetector,TextAssignment}.swift`
- **Why this is the real architecture:** boxes come from a model that recognises
  *controls*; text comes from a model that recognises *characters*. Neither can
  do the other's job. This is precisely why OmniParser pairs a detector with OCR
  rather than using OCR alone.
- **Until it exists:** tier 3 is not a standalone selection tier. Its output feeds
  tier 4's numbered marks, where the vision model disambiguates visually.

### 3.5 Window state guard

- **Acceptance:** Before observing, the harness raises the target window,
  unminimizes it, and confirms it is on-screen via `CGWindowListCopyWindowInfo`.
  If it cannot, the step fails **loudly** rather than returning zero candidates.
- **Verify:** `swift run Probe observe <app>` with the app minimized → explicit
  error, never an empty list.
- **Files:** `Sources/Harness/Perception/WindowGuard.swift`
- **Why:** a minimized or off-Space window observes as *empty, not as an error* —
  measured: Zen 1 node, Finder 2, ghostty 0, while `AXWindows` still reported
  handles. The agent reads that as "nothing actionable here" and proceeds on a
  screen it cannot see.

### 3.3 Browser lifecycle — *browser phase, after v1 ships*

- **Acceptance:** Launches Zen on the agent profile with the debug port, waits
  for readiness, tears down on task end. Never touches the user's profile.
- **Verify:** `swift run Probe browser-launch` — port listening within 20 s, and
  the user's running Zen is unaffected.
- **Files:** `Sources/Harness/Perception/BrowserLifecycle.swift`

---

## Phase 4 — The loop

### 4.1 Loop with fakes

- **Acceptance:** `AgentLoop` runs to completion against a fake `ElementSource`,
  fake `JevClient`, and fake `Executor`. Every recovery rung and every budget
  ceiling is exercised.
- **Verify:** `swift test --filter LoopTests`. Must include: a fake that never
  converges hits each ceiling; `blocked` is **never retried**; confirmation wait
  does **not** charge machine time.
- **Files:** `Sources/Harness/Core/Loop.swift`, `Sources/Harness/Core/Recovery.swift`

### 4.2 Planner

- **Acceptance:** OpenRouter call returns a schema-valid `Plan`. A malformed or
  empty plan surfaces to the user rather than retrying.
- **Verify:** `swift run Probe plan "open Zen, go to x.com, post about Jev"`
- **Files:** `Sources/Harness/Planning/{OpenRouterClient,Planner}.swift`

### 4.3 Executors

- **Acceptance:** BiDi click/type/navigate and AX press/set work against live
  targets. Typing uses **real key events** (`input.performActions`), not `.value`
  assignment — modern web apps do not observe the latter.
- **Verify:** `swift run Probe execute --bidi click "Search"` on a fixture page.
- **Files:** `Sources/Harness/Execution/{BiDiExecutor,AXExecutor}.swift`
- **Note:** the executor reports *mechanics*. It never reports progress — that is
  the next step's Jev batch, and conflating the two is the failure this whole
  design exists to prevent.

### 4.4 Composition

- **Acceptance:** Apple FM composes post text in ≤8 s. `guardrailViolation` and
  context overflow fall back to OpenRouter.
- **Verify:** `swift run Probe compose "a short post about Jev"`
- **Files:** `Sources/Harness/Composition/OnDeviceWriter.swift`
- **Constraint:** instructions ≤400 characters. 4,096 tokens is the *total*
  budget and a verbose instruction plus a schema overflows it before input.

### 4.5 Vision fallback

- **Acceptance:** On escalation, captures the **focused window only**, sends it
  with the candidate list, and returns the same `Action` type. It does not emit
  coordinates unless the target is genuinely absent from the candidates.
- **Verify:** `swift run Probe escalate --fixture canvas-page`
- **Files:** `Sources/Harness/Planning/VisionFallback.swift`

---

## Phase 5 — Application

### 5.1 HUD

- **Acceptance:** `NSPanel`, always-on-top, non-activating (never steals focus),
  380×120. Shows the instruction field, current step, elapsed, cost, Stop.
- **Verify:** Run it; drive a task; confirm the browser keeps keyboard focus
  throughout.
- **Files:** `Sources/ComputerAgent/HUD/`

### 5.2 Confirmation

- **Acceptance:** Expands in place showing the **exact payload**, never a summary.
  Approve / Edit / Cancel. **No timeout, no default.**
- **Verify:** `swift test --filter ConfirmationTests` plus a manual pass on the
  publish step.
- **Files:** `Sources/ComputerAgent/HUD/ConfirmationView.swift`
- **This is the only safety boundary the user sees.** Edit must let them change
  the payload before approving, or they will approve text they wanted to fix.

### 5.3 Step log

- **Acceptance:** Every step recorded with action, verdict probabilities, source,
  vision flag, cost, elapsed, and the Jev model version that answered.
- **Verify:** Run a task, inspect the log, confirm a replay is reconstructible.

---

## Phase 6 — Validation

### 6.1 The reference task

- **Acceptance:** SPEC.md § S1 passes end to end. Exactly one confirmation.
- **Verify:** `swift run Probe run-task "open Zen, go to x.com/ahammad_nafiz, write a short post about Jev, publish it"`

### 6.2 Induced failure

- **Acceptance:** With step 3 forced to a no-op, the agent detects it at step 4
  and recovers or stops — it does not continue on a stale screen.
- **Verify:** `swift run Probe run-task --inject-noop 3`

### 6.3 Suite metrics

- **Acceptance:** Over 10 representative tasks: **≥60% of steps on the fast path**
  (S5), fast-path p50 ≤ 700 ms (S6).
- **Verify:** `swift run Probe run-suite`
- **If fast-path share is below 60%:** the hybrid is not earning its complexity.
  Reopen [ADR 0002](./adr/0002-fast-path-reads-dom-not-accessibility.md) rather
  than tuning thresholds to hit the number.

---

## Dependency graph

```
0.1 X.com risk ──────┐            (can change the reference task, not the design)
0.2 Electron risk ───┤
0.3 Fixtures ────────┴──→ 1.4 Filter ──→ 2.3 Eval
                                             │
1.1 Package ──→ 1.2 Types ──→ 1.3 SAFETY ────┤
                     │                       │
                     ├──→ 2.1 Jev ──→ 2.2 Battery
                     │                       │
                     ├──→ 3.1 BiDi ──┐       │
                     ├──→ 3.2 AX ────┼──→ 4.1 Loop ──→ 4.3 Executors
                     │    3.3 Launch ┘       │
                     └──→ 4.2 Planner ───────┤
                          4.4 Compose ───────┤
                          4.5 Vision ────────┘
                                             │
                                        5.x HUD ──→ 6.x Validation
```

**Parallelisable:** 3.1/3.2/3.3 are independent of 2.x. 4.2/4.4/4.5 are
independent of each other.

**Strictly sequential:** 1.3 (Safety) before anything that can act. 0.3 (Fixtures)
before 1.4. 2.2 before 2.3.

---

## Definition of done, per task

1. Acceptance criterion demonstrably met by its verify command.
2. `swift test` green, `swift format lint` clean.
3. No numeric threshold outside `Constants.swift`.
4. Any new threshold carries provenance — what it was measured against.
5. If a Jev question changed: `Probe battery-eval` re-run and its numbers
   committed alongside.
6. If a decision was made that is hard to reverse, non-obvious, and had real
   alternatives: an ADR in `docs/adr/`.
