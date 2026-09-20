# Spec: Computer Agent

A macOS computer-use agent that executes natural-language tasks against real
applications. A System One model (Jev) does per-step selection and verification
cheaply enough to run on every step; a frontier model plans and sees; the
on-device model writes prose; code owns control flow and every irreversible
decision.

Domain vocabulary is defined in [CONTEXT.md](./CONTEXT.md). Architectural
decisions are in [docs/adr/](./docs/adr/). Detailed subsystem specs:

| Document | Covers |
|---|---|
| [docs/harness.md](./docs/harness.md) | The core loop, end to end. Types, contracts, sequencing. |
| [docs/jev-api-reference.md](./docs/jev-api-reference.md) | The vendor API in full — schemas, limits, patterns, failure modes, evidence. |
| [docs/jev-questions.md](./docs/jev-questions.md) | Every Jev battery *this project* uses, verbatim and ready to use. |
| [docs/element-sources.md](./docs/element-sources.md) | WebDriver BiDi and Accessibility, wire level. |
| [docs/models.md](./docs/models.md) | OpenRouter and Apple Foundation Models contracts. |
| [docs/build-sequence.md](./docs/build-sequence.md) | Ordered tasks with per-task verification. **Native-first** — ADR 0006. |

`jev-api-reference.md` is the reference for the API *as a whole*, independent of
this project — schemas, every verified limit, the patterns worth stealing, and
the evidence behind each claim. `jev-questions.md` is the subset this harness
actually sends. Read the reference once; read the questions file before every
change to a question.

---

## Objective

**Who it is for.** One person, on their own Mac, who wants to hand a multi-step
UI task to software instead of doing it by hand.

**What it does.** Accepts a sentence — *"open Zen, go to my X profile, write a
short post about Jev, publish it"* — and carries it out across real
applications, asking for confirmation only where an action cannot be undone.

**Why it is built this way.** Existing computer-use agents send a screenshot to
a vision model on every step. That costs 2–4 seconds and several cents per step,
which is expensive enough that most harnesses skip verification and simply hope
each action worked. When step 7 silently fails, steps 8–20 operate on the wrong
screen and the user discovers it at the end.

Jev changes that economics, and that is the entire thesis of this project:

> Verification costs **412 ms and $0.000027 per step** (measured). At that price
> you verify *every* step instead of none. The agent notices it is lost at step
> 7 rather than step 20.

**What success looks like.** See [Success Criteria](#success-criteria). The short
version: the example task completes end to end, the agent stops rather than
flailing when it cannot proceed, and no irreversible action ever occurs without
explicit approval.

**Explicit non-goals.**

- Not an autonomous agent. It does not choose its own objectives or run unattended.
- Not a scripting tool. No macro recording, no replay of fixed selectors.
- Not multi-user, not networked, not a service.
- Not a Jev benchmark. Jev is a component; if it proves unsuitable for a job,
  that job moves elsewhere.
- **Not a mouse.** It never moves a cursor, never plans in coordinates, and no
  model it calls returns one. On surfaces that expose no element tree it does
  synthesize a click at a box it identified by label — see Coverage below.

### Coverage — a gradient, not a boundary

The agent works **anywhere**. Accuracy and latency vary by how much the target
application is willing to tell us about itself.
[ADR 0005](./docs/adr/0005-coverage-is-a-gradient-not-a-boundary.md) has the
reasoning and the measurements.

| Tier | Source | Yields | Measured |
|---|---|---|---|
| **1** | DOM via WebDriver BiDi | label, role, state | **81% hit · 69% gated · 100% gate precision · 552 ms** |
| **2** | Accessibility tree | label, role, state, real actions | **100% hit · 100% gated · 100% gate precision · 473 ms** |
| **3** | Screen capture + Vision OCR | label, bbox | Electron (4% labelled), GPU-rendered, canvas |
| **3b** | ANE icon detector | bbox only | 58 ms at imgsz 1280 |
| **4** | Vision model + numbered marks | index + label | **83% — 100% text, 71% icon · 4.8 s** |

Tiers 1 and 2 *dispatch* to an element. Tiers 3 and 4 have no element to dispatch
to and actuate with a synthesized event instead — ADR 0007. Everything above the
executor is identical across all four.

Each step takes the highest tier available for its target and falls through on
failure. A task is never refused for being on the wrong surface; it is answered
more slowly and less accurately as it descends.

Three things that are easy to assume away:

- **Vision resolves a target, never a point.** It sees a screenshot with the
  candidates drawn on it as numbered boxes and returns a *number*, plus a short
  description of what it picked so the denylist has something to match. No model
  in this system ever emits a coordinate.
- **An identity is never a coordinate — but tiers 3 and 4 actuate with one.**
  Where a target has no element tree, `CapturedExecutor` computes a click point
  from that target's own bounding box at act time. It sits downstream of
  selection, the denylist and the confirmation gate, and it never appears in an
  `Action`, in a plan, or as a step's logged identity.
  [ADR 0007](./docs/adr/0007-captured-targets-execute-by-synthesized-event.md)
  has the reasoning and what it cost.
- **Tier 3 is a supplement, not the universal layer.** Measured across 7 apps
  and 624 pressable elements: OCR reaches 25.8%, accessibility labels 62.7%, and
  **74.2% of elements are icon-only with no text anywhere.** Icons go to tier 4.
- **Tier 3 is not a standalone selection tier.** Vision returns *line* boxes, so
  adjacent controls merge — `"Donate Create account Log in"` is one observation
  spanning three links. Splitting by gap was implemented and **measured to be
  impossible**: inter-link and intra-link spacing are identical at every
  resolution (2/2 px at DPR 1, 6/5 px at DPR 3). Control boundaries have to come
  from the tier-3b detector. Until then, tier 3 feeds tier 4's marks rather than
  being selected from.

---

### The browser the agent drives is its own, and this surprises people

**The agent cannot use a browser you already have open.** The BiDi debug port can
only be set at process start, so the agent launches its own Zen against its own
profile at `~/Library/Application Support/computer-agent/zen-profile`. A browser
you opened has no port and cannot be attached to, at any tier.

This is a safety decision, not a limitation to engineer away — see § Boundaries,
*never run against a profile holding accounts the user did not explicitly assign
to it.* The cost is a **one-time manual setup per site**: the agent profile
starts logged into nothing, so the first task touching a new site returns
`blocked ≈ 0.95` and stops. That is correct behaviour and it looks like a bug the
first time, so it is written down here.

The setup, once per site:

1. `swift run Probe browser-login` launches Zen on the agent profile.
2. Log in by hand. Complete any 2FA.
3. Quit. The session cookie now lives in the agent's profile.

Native targets have the equivalent prerequisite and it is cheaper: Accessibility
permission is granted **per binary**, so the shipped `.app` and the `Probe`
binary each need their own grant. Screen Recording is a third grant, and since
ADR 0007 it gates execution at tiers 3–4, not just observation.

---

## Tech Stack

| Layer | Choice | Version | Why |
|---|---|---|---|
| Language | Swift | 6.4 | Native AX and Foundation Models access; strict concurrency |
| UI | SwiftUI | macOS 26+ | Floating panel, `NSPanel` for always-on-top |
| Build | Swift Package Manager | — | No Xcode project file to merge-conflict on |
| Judgment | Jev `jev-1.13.0` | pinned | Selection, verification, risk triage |
| Planning | OpenRouter | — | `anthropic/claude-sonnet-5` ($2/M) |
| Vision escalation | OpenRouter | — | `google/gemini-3.8-flash` ($0.75/M) — measured, [ADR 0004](./docs/adr/0004-vision-is-cloud-and-returns-an-index.md) |
| Screen capture + OCR | ScreenCaptureKit + Vision | macOS 26 | on-device, `.accurate`, `minimumTextHeight = 0` |
| Composition | Apple Foundation Models | macOS 26 | On-device, free, 4k context |
| Web perception + execution | WebDriver BiDi | — | Gecko/Zen; DOM as text |
| Native perception + execution | `ApplicationServices` AX | — | Cocoa apps |
| WebSocket | `URLSessionWebSocketTask` | — | Foundation; no dependency needed |

**Model versions are pinned, never aliased.** Jev's own documentation warns that
`jev-latest` moves and answers change without a code change on your side. Every
threshold in this system is tuned against `jev-1.13.0` specifically.

---

## Commands

```bash
# Build
swift build -c release

# Run (requires Accessibility permission for the built binary)
swift run ComputerAgent

# Test — all
swift test

# Test — one suite
swift test --filter SafetyTests

# Lint / format
swift format lint --recursive Sources Tests
swift format --in-place --recursive Sources Tests

# Live probes against the real APIs (not part of `swift test`)
swift run Probe jev-latency
swift run Probe bidi-dom https://en.wikipedia.org/wiki/Accessibility
swift run Probe ax-tree Finder
swift run Probe battery-eval          # replays the fixture set, prints accuracy
```

`Probe` is a second executable target. It exists because the interesting failure
modes of this system are in live API behaviour, not in pure logic, and those
cannot live in `swift test` without making the suite slow and flaky.

---

## Project Structure

```
computer-agent/
├── Package.swift
├── SPEC.md                      This document
├── CONTEXT.md                   Domain glossary
├── docs/
│   ├── adr/                     Architectural decision records
│   ├── harness.md               Core loop, end to end
│   ├── jev-questions.md         Question batteries, verbatim
│   ├── element-sources.md       BiDi + AX, wire level
│   ├── models.md                OpenRouter + Apple FM contracts
│   └── build-sequence.md        Ordered build plan
├── Sources/
│   ├── ComputerAgent/           Executable: SwiftUI app entry
│   │   ├── App.swift
│   │   └── HUD/                 Floating panel, confirmation sheet
│   │       ├── CursorOverlay.swift  Click-through panel + coordinate flip
│   │       └── CursorView.swift     Cursor, target ring, narration, ripple
│   ├── Harness/                 Library: everything headless
│   │   ├── Core/
│   │   │   ├── Task.swift       Task, Step, Outcome
│   │   │   ├── Action.swift     Action, ActionKind, ElementRef
│   │   │   ├── Loop.swift       The agent loop
│   │   │   └── Budget.swift     Step/time/cost ceilings
│   │   ├── Perception/
│   │   │   ├── ElementSource.swift    Protocol
│   │   │   ├── BiDiSource.swift       Web
│   │   │   ├── AXSource.swift         Native
│   │   │   └── CandidateFilter.swift  Deterministic reduction
│   │   ├── Judgment/
│   │   │   ├── JevClient.swift
│   │   │   ├── Batteries.swift  Question definitions
│   │   │   └── StepVerdict.swift
│   │   ├── Planning/
│   │   │   ├── OpenRouterClient.swift
│   │   │   ├── Planner.swift
│   │   │   └── VisionFallback.swift
│   │   ├── Composition/
│   │   │   └── OnDeviceWriter.swift   Apple FM
│   │   ├── Execution/
│   │   │   ├── Executor.swift         Protocol + total `for(ref:)` switch
│   │   │   ├── BiDiExecutor.swift
│   │   │   ├── AXExecutor.swift
│   │   │   └── CapturedExecutor.swift Tiers 3–4, synthesized events — ADR 0007
│   │   ├── Safety/
│   │   │   ├── Irreversibility.swift  Upgrade-only classifier
│   │   │   └── LabelDenylist.swift
│   │   └── Config/
│   │       └── Constants.swift        EVERY threshold, one file
│   └── Probe/                   Executable: live API probes
└── Tests/
    ├── SafetyTests/             Irreversibility, denylist, upgrade-only
    ├── CandidateFilterTests/    Reduction logic, fixture DOMs
    ├── LoopTests/               Recovery ladder, budgets, with fakes
    ├── BatteryTests/            Jev responses replayed from fixtures
    └── Fixtures/
        ├── dom/                 Captured DOM snapshots
        ├── ax/                  Captured AX trees
        └── jev/                 Recorded Jev responses
```

**`Constants.swift` is load-bearing and deliberately isolated.** TypeSafe's own
agent skill says to keep questions and thresholds as constants in a single file,
because that is the file a human reviews. Nothing anywhere else in this codebase
may contain a numeric threshold.

---

## Code Style

Swift API Design Guidelines, `swift format` with the default configuration.
Strict concurrency; every long-running component is an `actor`.

The style that matters is not formatting — it is that **judgment and policy never
mix**. A model result is read, then a named constant decides what happens. This
is the shape every decision site takes:

```swift
/// Classifies an action's reversibility. Can only ever escalate, never relax.
///
/// Two independent mechanisms run: what the planner declared, and what a
/// deterministic label rule found. The stricter of the two wins. Nothing in
/// this system may move an action from `.irreversible` to `.reversible` —
/// see docs/adr/0001-irreversibility-is-upgrade-only.md.
func classify(_ action: Action, target: Element) -> Reversibility {
    let declared: Reversibility = action.kind.isIrreversibleByDefault
        ? .irreversible : .reversible
    let byLabel: Reversibility = LabelDenylist.matches(target)
        ? .irreversible : .reversible

    return max(declared, byLabel)   // Reversibility: Comparable, irreversible > reversible
}
```

Conventions, in order of how often they are violated:

- **No magic numbers outside `Constants.swift`.** `if verdict.blocked > 0.7` is a
  bug; `if verdict.blocked > Constants.Jev.blockedThreshold` is correct.
- **Probabilities are never booleans until a named constant makes them one.**
  Pass `Double` around; threshold once, at the decision site.
- **Every model call site names its failure mode in a comment.** Which jagged
  edge applies here, and what catches it if the model is wrong.
- **A coordinate exists in exactly one file.** `CapturedExecutor` turns a
  `.captured` ref's bbox into a click point. If `x`/`y` or a `CGPoint` appears
  anywhere else — in an `Action`, a plan, a Jev state, a log's identity field, or
  a model's response type — the design has been violated. See
  [ADR 0001](./docs/adr/0001-irreversibility-is-upgrade-only.md) and
  [ADR 0007](./docs/adr/0007-captured-targets-execute-by-synthesized-event.md).
- **Errors are typed and exhaustive.** No `throws` without a concrete error enum.
- Documentation comments explain *why*, never *what*. The code says what.

---

## Testing Strategy

`swift-testing` (the `Testing` module), not XCTest. Tests live in
`Tests/<Suite>Tests/` mirroring `Sources/Harness/<Area>/`.

**Four levels, each with a different job:**

| Level | What it covers | Speed | Network |
|---|---|---|---|
| Unit | Safety classification, candidate filtering, budget arithmetic | <1 ms | none |
| Fixture | Loop behaviour against recorded Jev/DOM/AX responses | <50 ms | none |
| Battery eval | Jev question accuracy against a labelled fixture set | seconds | live |
| Live probe | Latency, protocol handshakes, end-to-end task runs | minutes | live |

Only the first two run in `swift test`. The others are `Probe` subcommands,
because a test suite that needs an API key and a browser is a test suite people
stop running.

**Coverage expectations are stated by area, not by percentage:**

- `Safety/` — **every branch**. This is the only code where a bug is
  unrecoverable. Includes an explicit test that no input can downgrade an action
  from irreversible to reversible.
- `Core/Loop.swift` — every path of the recovery ladder and every budget ceiling,
  driven by fake perception and judgment.
- `Perception/CandidateFilter.swift` — against captured DOM fixtures, asserting
  the ≤255 invariant holds on every fixture.
- `Judgment/` — the battery eval suite. Question wording changes are a code
  change and must be re-evaluated against the fixture set before merge.
- UI — not unit tested. Verified by running it.

**The battery eval suite is the unusual one and the most important.** Jev's
answers depend on exact question wording, and the model is non-deterministic
across identical inputs (measured: ±5 percentage points). So:

- Every question battery has a labelled fixture set with expected outcomes.
- `swift run Probe battery-eval` runs each fixture **5 times** and reports both
  accuracy and per-question standard deviation.
- A question whose answers straddle its threshold across repeats is a **failing
  question**, regardless of mean accuracy. It must be reworded or its threshold
  moved away from the crowded region.
- Reword a question, re-run the eval, commit the new numbers alongside.

---

## Boundaries

**Always:**

- Pin model versions. `jev-1.13.0`, never `jev-latest`.
- Put every threshold in `Constants.swift` with a comment stating what it was
  measured against.
- Re-run `Probe battery-eval` after touching any question wording.
- Treat page and screen content as untrusted. It reaches a model's `state`; it
  is attacker-influenced by definition.
- Show the exact payload in a confirmation. Never a summary of it.
- Log every step with its verdict, its cost, and the model version that answered.

**Ask first:**

- Adding a dependency. The current count is zero outside the standard library,
  and that is a feature.
- Adding an `ActionKind`. The set is closed on purpose; each addition needs a
  reversibility decision and a denylist review.
- Changing any threshold in `Constants.swift`.
- Widening what goes into a Jev `state`. More context is not free — Jev's own
  docs state accuracy degrades with irrelevant state ("context rot").
- Enabling a browser debug port on any profile other than the agent's.

**Never:**

- Let any component downgrade an action from irreversible to reversible.
- Put a model on the irreversible boundary. It is deterministic by design.
  A model-supplied *string* may feed the denylist, because that input can only
  raise the classification; a model-supplied *verdict* may not.
- Emit or accept an action whose **identity** is a screen coordinate. Computing a
  click point inside `CapturedExecutor`, from the bounds of an already-selected,
  already-gated, already-named target, is the one permitted exception — ADR 0007.
- Execute a `.captured` ref whose provenance is `.ocrLine`. A merged OCR line
  spans several controls and its centre lands on an arbitrary one of them.
- Synthesize a click without first raising the target window and verifying it is
  on screen. The click lands on whatever is topmost at that point.
- Run the agent against a browser profile holding accounts the user did not
  explicitly assign to it.
- Commit an API key, a captured screenshot, or a DOM fixture containing session
  tokens.
- Count human confirmation time against the task's wall-clock budget.

---

## Success Criteria

Concrete and testable. Each maps to a verification command.

**S1 — The v1 reference task completes.**
*"Open Mail, reply to the most recent message from <person> saying I'll get back
to them tomorrow, and send it."*

Runs end to end. Exactly one confirmation is requested (the send). The reply text
is composed on-device. Verified by `Probe run-task`.

Chosen to exercise every mechanism rather than to impress: accessibility
navigation across an app, Apple FM composition, and the deterministic
irreversible gate at `send`. The publish-to-X task returns as the **tier-1**
reference task when browser support lands — see
[ADR 0006](./docs/adr/0006-native-first-sequencing.md).

**S2 — Verification catches induced failure.**
With a fault injected that makes one action a no-op, the agent detects it on the
*next* step rather than continuing. Asserted in `LoopTests` against fixtures, and
observed live in `Probe run-task --inject-noop 3`.

**S3 — No unconfirmed irreversible action is reachable.**
`SafetyTests` proves that for every `ActionKind` and every denylist-matching
label, `classify` returns `.irreversible`, and that no code path executes an
irreversible action without an approval token.

**S4 — Budgets bound everything.**
No task exceeds 40 steps, 90 seconds of machine time, 3 vision escalations,
2 replans, or $0.25. Ceilings are asserted in `LoopTests` with a fake that never
converges.

**S5 — The fast path carries the majority of steps. — MEASURED, PASSING.**
≥60% of steps resolve without vision escalation.

> **Blended across both fast tiers, 32 intents, 2026-09-18:**
> **27/32 = 84% of steps passed the gate** (`confidence ≥ 0.80 ∧ margin ≥ 0.25`),
> and **27 of 27 were correct — 100% fast-path precision.**
>
> | Tier | Intents | Raw hit | Gated | Gate precision | Latency |
> |---|---|---|---|---|---|
> | 1 — DOM, 4 real sites | 16 | 81% | 69% | **11/11** | 552 ms |
> | 2 — AX, Finder + Settings | 16 | **100%** | **100%** | **16/16** | 473 ms |
> | **blended** | **32** | **91%** | **84%** | **27/27** | ~500 ms |
>
> Tier 2 outperforms tier 1 because accessibility labels are clean and semantic
> (`Time Machine`, `NDA - Ahammad Nafiz.pdf`) where DOM labels on real pages are
> noisy — repeated nav links, ad frames, decorative anchors. Selections included
> genuine semantic jumps: *"erase this Mac and start over"* → `Transfer or Reset`,
> *"adjust the clock"* → `Date & Time`, *"the ICCIT conference paper"* →
> `BnSFD ICCIT 2025.pdf` out of 91 filenames.
>
> **Caveat:** n=32, four sites and two apps, intents written by the author. This
> is strong enough to proceed on and not strong enough to quote as a benchmark.

**S6 — Step latency holds. — MEASURED, PASSING.**
Fast-path step p50 ≤ 700 ms end to end from this machine, including the ~250 ms
round trip to Jev.

> **Measured 552 ms median** for DOM extraction plus the full Jev step battery on
> real pages. Jev alone: 468–552 ms. Vision escalation: 4.8 s.

**S7 — Candidate sets always fit.**
Across every captured DOM and AX fixture, the filtered candidate set is ≤255.
Asserted in `CandidateFilterTests`.

**S8 — Questions are stable at their thresholds.**
Every battery question, over 5 repeats on its fixture set, stays on one side of
its threshold. Reported by `Probe battery-eval`.

---

## Open Questions

**Q1 — X.com under automation. Unresolved and highest risk.**
X fingerprints automated browsers aggressively. A BiDi-driven Zen profile may be
challenged, rate-limited, or locked, and the example task is the headline demo.
*Resolve before building the executor.* Verification: log into the agent profile
by hand, drive one navigation and one compose via BiDi, observe whether a
challenge appears. If it does, S1's reference task changes site and X support
becomes its own problem.

**Q2 — Electron unlock. Mechanism confirmed, effect unmeasured.**
`AXManualAccessibility` is settable on Cursor and rejected by Chrome, Safari, Zen
and Finder — the expected Electron-only signature, and it is implemented in
Electron's `electron_application.mm`. The unlock carries a hard-coded ~2 s
debounce. What it actually yields in elements has not been measured, because the
app has never had an on-screen window during testing. GPU-rendered applications
(ghostty, games, canvas editors) cannot be unlocked at all and are tier 3/4
permanently.

**Q6 — Window state is a prerequisite nobody specced. — NEW, and it blocks testing.**
A minimized or off-Space window observes as **empty, not as an error**: Zen
returned 1 AX node, Finder 2, ghostty 0, while `AXWindows` still reported handles.
The agent would read that as "nothing actionable here." Worse, `AXWindows`
intermittently returns an empty array for windows that demonstrably exist —
Notes and Cursor returned 0 after 8 retries over 3.2 s, while Zen and Finder
returned on the first try. And raising windows programmatically (`unhide`,
`activate`, clearing `AXMinimized`, `AXRaise`) did **not** bring windows from
another Space onto the current one.

The harness must raise the target window, verify it is on-screen via
`CGWindowListCopyWindowInfo`, and fail loudly when it cannot. Observation must
retry with backoff rather than trusting a single read.

**Q3 — Deadband width for non-determinism.**
Jev drifts ±5pp on identical input. Every threshold needs hysteresis so a
borderline value does not oscillate between steps. The mechanism is decided
(a decision, once made, is sticky for N steps unless the probability moves by
more than the deadband) but N and the deadband width are not.

**Q4 — Apple FM guardrail fallback.**
On-device composition refuses unpredictably (measured: `guardrailViolation` on a
benign UI-automation prompt). The fallback is to route composition to OpenRouter,
but whether that happens silently or surfaces to the user is undecided. Silent
fallback contradicts "on-device" as a product claim.

**Q5 — Multi-window and Spaces.**
Which window the agent operates on when an app has several, and what happens when
the target is on another Space, is entirely unspecified. Native scope makes this
real; browser-only scope would have avoided it.

**Q7 — The captured tier is entirely unmeasured. — NEW, and it is the largest
unknown in the system.**
[ADR 0007](./docs/adr/0007-captured-targets-execute-by-synthesized-event.md) makes
tiers 3 and 4 executable, and unlike every other decision here it rests on reading
the types rather than on numbers from this machine. Three things need measuring
before any of it is trusted: the end-to-end hit rate of a captured click on a real
GPU-rendered surface; how often tier 4 returns a label the denylist can use; and
how often `confirmUnnamedCaptured` actually fires, since if it is frequent the
real defect is tier 4's label output rather than the flag. Needs a
`Probe captured-eval` subcommand with a labelled fixture set, the same shape as
`battery-eval`.

**Q8 — `pressKey(.enter)` on native targets has no submission target. — NEW.**
[ADR 0008](./docs/adr/0008-keystrokes-are-an-action-kind.md) classifies `enter`
against the focused element's implicit submission target, which is computable in
the DOM and does not exist in the accessibility API. The uncovered case is a
native text field whose window sends on `enter` with no denylist-reachable label.
No example has been collected yet. If one exists, the mitigation is to classify
`pressKey(.enter)` as irreversible for `.ax` targets by default and absorb the
extra confirmations.
