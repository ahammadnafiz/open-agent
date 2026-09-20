# The Harness

The core loop, end to end. Types, contracts, sequencing, and the reasoning
behind the shape. Terms are defined in [../CONTEXT.md](../CONTEXT.md).

---

## 1. The shape in one page

```
runTask(instruction)
│
├─ Budget()                      40 steps / 90s machine / 3 escalations / 2 replans / $0.25
├─ Planner.plan(instruction)     OpenRouter, ONCE. Produces a Plan (a hypothesis, not a script).
│
└─ loop until done, failed, or budget exhausted:
   │
   │  ── OBSERVE ───────────────────────────────────────────────
   ├─ source = ElementSource.for(currentTarget)       BiDi if browser, AX if native
   ├─ world  = source.observe()                       raw elements
   ├─ cands  = CandidateFilter.reduce(world)          rendered ∧ onscreen ∧ labelled → ≤255
   │
   │  ── JUDGE ─────────────────────────────────────  ONE Jev call, ~412 ms, $0.000027
   ├─ verdict = Jev.step(StepContext(
   │              task, planStep, lastAction,
   │              screenBefore, screenNow, history, candidates))
   │
   │            returns, in a single batched request:
   │              progressed   did the last action move the task forward
   │              unchanged    is the screen effectively identical
   │              blocked      login wall / permission / captcha / error
   │              taskDone     is the whole task visibly complete
   │              looping      is recent history repeating
   │              target       Choice over candidate ids  ← the selection
   │              sufficient   is this element list enough, or do we need eyes
   │              risk*        intent-level risk nouls
   │
   │  ── ROUTE ─────────────────────────────────────────────────
   ├─ if verdict.taskDone           → finish(.succeeded)
   ├─ if verdict.blocked  ≥ T       → surface to user, STOP. Never retried.
   ├─ if verdict.looping  ≥ T       → escalate once, then STOP.
   ├─ if ¬verdict.progressed        → RecoveryLadder.next()
   ├─ if verdict.sufficient < T
   │     ∨ verdict.target.confidence < T
   │                                 → VisionFallback.decide(screenshot)   2–4 s
   │  else                           → action from verdict.target          fast path
   │
   │  ── GATE ──────────────────────────────────────  deterministic, no model
   ├─ effective = Irreversibility.classify(action, target)     upgrade-only
   ├─ if effective == .irreversible → await HUD.confirm(exact payload)
   ├─ else if verdict.riskMax ≥ T   → await HUD.confirm(exact payload)
   │
   │  ── ACT ───────────────────────────────────────────────────
   ├─ result = Executor.for(source).execute(action)
   └─ history.append(Step(action, result, verdict, cost))
        ↑ verification of THIS step happens in the NEXT iteration's Jev call
```

**The one structural idea worth internalising:** verification and selection ride
in the *same* Jev request. Jev evaluates every question in a batch against one
shared state, in parallel — measured flat from 1 to 25 questions. So asking
"did the last thing work?" alongside "what do I click next?" is free. A design
that verifies in a separate call pays twice for nothing.

---

## 2. Types

### 2.1 Action

```swift
/// What the agent can do. Closed set, deliberately.
///
/// Additions require a reversibility decision and a denylist review — see
/// SPEC.md § Boundaries. `kind` is what the deterministic safety layer gates on,
/// which is the entire reason this is an enum and not a string.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    // Reversible
    case openApp, navigate, click, type, scroll, focus, select, read, wait
    // Irreversible by default — always confirmed, never auto-executed
    case publish, send, delete, purchase

    var isIrreversibleByDefault: Bool {
        switch self {
        case .publish, .send, .delete, .purchase: true
        default: false
        }
    }
}

/// Identity of a UI element. Never coordinates — see ADR 0001.
///
/// A coordinate cannot be risk-gated: nobody can tell whether clicking (847,203)
/// publishes a post or scrolls a list. Both cases below carry enough identity to
/// be named in a confirmation dialog and re-resolved on a later step.
public enum ElementRef: Codable, Sendable, Hashable {
    /// Web. `handle` is a BiDi script.NodeRemoteValue sharedId; `selector` is a
    /// human-readable fallback used for logging and re-resolution after reload.
    case dom(handle: String, selector: String, label: String)
    /// Native. `path` is the index chain from the window root, which is stable
    /// only within one observation — always re-observe before acting.
    case ax(path: [Int], role: String, label: String)

    var label: String { … }
}

public struct Action: Codable, Sendable {
    public let kind: ActionKind
    public let target: ElementRef?      // nil only for openApp / wait
    public let payload: String?         // text to type, url to navigate, app to open
    public let rationale: String        // one line, for the log and the confirmation
}
```

### 2.2 Plan and Step

```swift
/// Produced once, at task start. A hypothesis about the route.
///
/// The agent is EXPECTED to depart from it. Departure is not failure — it is the
/// normal case, because a planner that has not seen the screen is guessing about
/// layout. The plan supplies intent for each step; the screen supplies reality.
public struct Plan: Codable, Sendable {
    public let steps: [PlanStep]
}

public struct PlanStep: Codable, Sendable {
    public let kind: ActionKind
    public let target: String       // semantic description: "the compose button"
    public let payload: String?
    public let declaredIrreversible: Bool   // planner's own claim; see ADR 0001
}

/// One completed iteration. Append-only; this is the audit log.
public struct Step: Sendable {
    public let index: Int
    public let action: Action
    public let result: ExecutionResult
    public let verdict: StepVerdict
    public let source: SourceKind          // .bidi or .ax
    public let usedVision: Bool
    public let cost: Cost
    public let elapsed: Duration
}
```

### 2.3 StepVerdict

Every field is a raw probability. **Nothing in this type is a boolean.**
Thresholding happens exactly once, at the decision site, against a named constant.

```swift
public struct StepVerdict: Sendable {
    // Verification — about the step that just happened
    public let progressed: Double    // noul
    public let unchanged: Double     // noul
    public let blocked: Double       // noul
    public let taskDone: Double      // noul
    public let looping: Double       // noul

    // Selection — about the step about to happen
    public let target: ChoiceAnswer  // .choice, .probabilities, .confidence
    public let sufficient: Double    // noul: is this element list enough?

    // Intent risk — about the planned step, not the resolved element
    public let riskDestructive: Double
    public let riskOutbound: Double
    public let riskCredential: Double

    public var riskMax: Double {
        max(riskDestructive, riskOutbound, riskCredential)
    }

    public let modelVersion: String  // e.g. "jev-1.13.0" — recorded per step
    public let usage: Usage
}
```

`riskMax` uses `max`, never a mean. One confident red flag must win; averaging
buries it. This is the aggregation that took the risk gate from 4/14 errors to
2/14 in measurement.

### 2.4 Budget

```swift
/// Hard ceilings. Every one of these has stopped a runaway in testing.
public struct Budget: Sendable {
    var steps        = Constants.Budget.maxSteps          // 40
    var machineTime  = Constants.Budget.maxMachineTime    // 90 s
    var escalations  = Constants.Budget.maxEscalations    // 3
    var replans      = Constants.Budget.maxReplans        // 2
    var dollars      = Constants.Budget.maxDollars        // 0.25

    /// Time spent waiting for a human NEVER counts. A task must not die because
    /// the user took a minute to read a confirmation.
    mutating func chargeMachineTime(_ d: Duration) { … }
    func exhausted() -> BudgetCeiling? { … }
}
```

---

## 3. Perception

### 3.1 The protocol

```swift
public protocol ElementSource: Sendable {
    /// Everything actionable the source can see, unfiltered.
    func observe() async throws -> [Element]
    /// A compact textual rendering for the Jev `state`. NOT the same as observe().
    func describe(_ elements: [Element]) -> String
    var kind: SourceKind { get }
}

public struct Element: Sendable, Hashable {
    public let ref: ElementRef
    public let role: String        // "button", "link", "textbox", "AXButton"
    public let label: String       // aria-label ∨ innerText ∨ value ∨ placeholder ∨ title
    public let enabled: Bool
    public let inViewport: Bool
    public let bounds: CGRect      // used ONLY by the filter and by vision, never by an action
}
```

`bounds` exists for filtering and for handing a screenshot region to the vision
model. It never reaches an `Action`. If it does, ADR 0001 has been violated.

### 3.2 Choosing a source

```swift
enum SourceKind { case bidi, ax }

// The target world is a property of the current step, not of the task.
// A task can cross the boundary: open Finder (ax) → drag a file into the
// browser (bidi). The loop re-decides every step.
func sourceFor(_ step: PlanStep, focusedApp: NSRunningApplication) -> SourceKind {
    Constants.Browser.bundleIDs.contains(focusedApp.bundleIdentifier ?? "")
        ? .bidi : .ax
}
```

### 3.3 The candidate filter

Deterministic. **No model participates in deciding what is a candidate** — a
model that filters its own option set can hide the right answer from itself.

```
keep an element iff
    rendered            width ≥ 1 ∧ height ≥ 1
  ∧ visible             visibility ≠ hidden ∧ display ≠ none ∧ opacity ≠ 0
  ∧ in viewport         bounds intersect the visible rect
  ∧ labelled            non-empty label after trimming
  ∧ addressable         has an actionable role or an explicit ARIA role
```

Measured on real pages, this reduces far below the 255 ceiling:

| Page | All actionable | In viewport | + labelled |
|---|---|---|---|
| en.wikipedia.org/wiki/Accessibility | 913 | 45 | **42** |
| news.ycombinator.com | 227 | 147 | **127** |
| github.com/typesafe-ai | 217 | 45 | **44** |
| Finder window (AX) | 174 nodes | — | **33** |
| Notes window (AX) | 44 nodes | — | **12** |

Worst observed is 127 on a link-dense page. No chunking or pre-ranking stage is
needed, and none should be added speculatively. If a page ever exceeds 255,
`CandidateFilter` throws `.tooManyCandidates` and the step escalates to vision
rather than silently truncating — **truncation would remove the correct answer
without anyone noticing**, which is the worst available failure.

---

## 4. Judgment

One Jev request per step. The full battery is in
[jev-questions.md](./jev-questions.md); this section covers how it is wired.

### 4.1 The state

```swift
struct StepContext: Encodable {
    let task: String                  // the user's original sentence
    let plan_step: PlanStepDTO        // intent for this step
    let last_action: ActionDTO?       // nil on step 0
    let screen_before: String         // describe() from BEFORE the last action
    let screen_now: String            // describe() from NOW
    let recent_history: [String]      // last N action summaries, N = 4
    let candidates: [String: String]  // id → label, the Choice option set
}
```

**Keep this minimal and resist growing it.** Jev's documentation is explicit that
accuracy falls as `state` grows with content unrelated to the decision — they
call it context rot. `screen_before` and `screen_now` are the *filtered* element
lists, not raw DOM and not the full page text.

### 4.2 Candidate ids

Candidate keys are opaque (`e0`, `e1`, …), and the values are the labels. Keys
are never sent as meaningful text — Jev's docs note that question ids are not
sent to the model, and the same discipline applies here: the *label* carries the
signal, the id is only how code finds the element again.

```swift
let candidates = Dictionary(uniqueKeysWithValues:
    filtered.enumerated().map { ("e\($0.offset)", $0.element.label) })
// resolution after the answer comes back
let chosen = filtered[Int(verdict.target.choice.dropFirst())!]
```

### 4.3 Reading the answer

```swift
// Selection confidence gates escalation. Jev's `confidence` is
//     (n · p_max − 1) / (n − 1)
// derived and confirmed against the live model to 4/4 exact matches. It reads
// ONLY p_max, so it is blind to where the runner-up sits. When the margin
// matters — and for element selection it does — read `probabilities` directly.
let p = verdict.target.probabilities.values.sorted(by: >)
let margin = p.count > 1 ? p[0] - p[1] : p[0]

let confidentEnough =
    verdict.target.confidence >= Constants.Jev.selectionConfidence   // 0.80
    && margin >= Constants.Jev.selectionMargin                       // 0.25
```

Two candidates at 0.48 and 0.47 produce a perfectly reasonable-looking
`confidence`, and picking either is a coin flip. The margin check is what
catches that, and it is the reason `probabilities` is carried on the type at all.

### 4.4 Jagged edges that apply here

Each is a documented `jev-1.13` failure mode with a real consequence in this loop.

| Edge | Where it bites | What catches it |
|---|---|---|
| Literal reading | "did it succeed" answered about mechanics, not progress — measured 0.54 on a login wall | Question reworded to name *progress*; `blocked` covers it independently |
| Adversarial state | Page text reaches `state`; a reframing moved a risk score 0.98 → 0.42 in measurement | Deterministic irreversible gate; Jev never decides the boundary |
| Non-determinism ±5pp | A threshold sitting near a verdict oscillates between steps | Deadband + sticky decisions (Open Question Q3) |
| Context rot | Large `screen_now` degrades every answer in the batch | Filter before describing; never send raw DOM |
| Cannot count | "how many unread" style questions | Not asked. Code counts. |
| Cannot compare dates | Any temporal ordering | Not asked. Code compares. |
| No structural invariance | A Noul and a Choice over the same question disagree (0.22 vs 0.01 in their docs) | Never compare across primitives; never reuse a threshold across question types |

---

## 5. Routing and recovery

### 5.1 Conditions are distinct and get distinct treatment

```swift
enum StepOutcome {
    case progressed        // continue
    case failed            // acted, no progress → ladder
    case blocked(String)   // external obstacle → STOP, surface
    case stuck             // repeating → escalate once → STOP
    case done              // task complete
}
```

`blocked` is never retried. Retrying a login wall produces another login wall;
the agent has no credential to offer and no amount of retrying invents one. This
distinction is why `blocked` is a separate question from `progressed`, and it is
what rescued the one measured verification miss.

### 5.2 The ladder

Applies only to `failed`. Each rung is attempted at most once per step index.

```
rung 0   retry the same action              clicks genuinely miss; cheapest possible fix
rung 1   escalate this step to vision       the element list was wrong or insufficient
rung 2   replan from the current screen     the plan's assumption about the route was wrong
rung 3   stop, surface state, ask the user
```

```swift
actor RecoveryLadder {
    private var rungByStep: [Int: Int] = [:]

    func next(for stepIndex: Int, budget: inout Budget) -> Recovery {
        let rung = (rungByStep[stepIndex] ?? -1) + 1
        rungByStep[stepIndex] = rung
        switch rung {
        case 0: return .retry
        case 1: return budget.escalations > 0 ? .escalate : .replan
        case 2: return budget.replans > 0 ? .replan : .surface
        default: return .surface
        }
    }
}
```

Budget exhaustion short-circuits a rung rather than failing the task outright —
a task that has used its escalations can still replan, and one that has used its
replans still surfaces cleanly rather than being killed mid-action.

---

## 6. The safety gate

Deterministic. Runs after selection, before execution, on every action. No model
input reaches it.

```swift
enum Reversibility: Comparable { case reversible, irreversible }   // irreversible > reversible

func classify(_ action: Action, target: Element?) -> Reversibility {
    let declared: Reversibility =
        action.kind.isIrreversibleByDefault ? .irreversible : .reversible
    let byLabel: Reversibility =
        target.map { LabelDenylist.matches($0) } ?? false ? .irreversible : .reversible
    return max(declared, byLabel)
}
```

`LabelDenylist` is a compiled regex over the target's label and role, plus a
`role == "submit"` check. It exists because **the verb never tells you what a
click does** — publishing a tweet is `click("Post")`, and `click` is reversible.
The declared intent and the label rule are independent; both must fail silently
and simultaneously for an unconfirmed irreversible action to occur.

Accepted cost: a search form whose button says "Submit" asks once. That is the
correct direction to be wrong in.

**The invariant, restated because it is the one thing that must not rot:** no
component may return `.reversible` for an action another component called
`.irreversible`. `SafetyTests` asserts this exhaustively across every
`ActionKind` × every denylist-matching label.

---

## 7. Execution

```swift
public protocol Executor: Sendable {
    func execute(_ action: Action) async throws -> ExecutionResult
}
```

**BiDi** — `script.callFunction` against the element's `sharedId` for click and
focus, `input.performActions` for real key events when typing (synthetic `value`
assignment does not fire the listeners that modern web apps depend on),
`browsingContext.navigate` with `wait: "complete"` for navigation.

**AX** — `AXUIElementPerformAction(el, kAXPressAction)` for click,
`AXUIElementSetAttributeValue(el, kAXValueAttribute, …)` for typing where
supported, falling back to `CGEvent` key synthesis with the element focused.

Both return a result carrying whether the call itself succeeded. **That is not
verification.** A click can be dispatched perfectly and change nothing; only the
next step's Jev batch knows whether the task moved. The executor reports
mechanics; Jev reports progress. Conflating the two is the failure this whole
architecture exists to prevent.

---

## 8. Concurrency

```swift
public actor AgentLoop {
    private let source: ElementSourceRegistry
    private let jev: JevClient          // actor, one shared HTTPS connection
    private let router: OpenRouterClient
    private let writer: OnDeviceWriter
    private let hud: HUDBridge          // @MainActor, awaits human approval
}
```

Rules, each of which exists because of a real failure mode:

- **One task at a time.** `AgentLoop` is an actor; concurrent tasks driving the
  same screen is nonsense.
- **`JevClient` holds a warm connection.** Measured: 383 ms warm versus ~900 ms
  cold, because TLS and TCP setup to their edge costs ~520 ms from this location.
  Reconnecting per step would more than double step latency.
- **Confirmation suspends the loop and stops the machine-time clock.**
  `await hud.confirm(...)` is the only unbounded wait in the system.
- **Stop is cooperative and checked at every await point.** A `Stop` that only
  takes effect after the current action is not a stop button.

---

## 9. Worked example

`"Open Zen, go to x.com/ahammad_nafiz, write a short post about Jev, publish it"`

| # | Source | Action | Jev verdict (prev step) | Gate | ms |
|---|---|---|---|---|---|
| 0 | — | plan | — | — | ~2500 |
| 1 | ax | `openApp` Zen (agent profile, `--remote-debugging-port`) | — | auto | ~1500 |
| 2 | bidi | `navigate` x.com/ahammad_nafiz | progressed 0.97 | auto | ~800 |
| 3 | bidi | `click` compose | progressed 0.95, sufficient 0.93 | auto | ~410 |
| 4 | — | compose text on-device (Apple FM) | — | — | ~1330 |
| 5 | bidi | `type` post body | progressed 0.97 | auto | ~600 |
| 6 | bidi | `publish` Post button | progressed 0.95 | **CONFIRM** | human |
| 7 | bidi | — | taskDone 0.95 | — | ~410 |

Machine time ≈ 7.6 s. Jev cost ≈ 6 × $0.000027 ≈ **$0.00016**. Plan ≈ $0.005.
Vision: not used. One confirmation, showing the exact post text.

The failure path is the more instructive one. If step 3's click does nothing,
step 4's batch returns `progressed 0.03, unchanged 0.84`. The ladder retries the
click once. Still unchanged, so it escalates: one screenshot, one vision call,
2–4 s and roughly a cent. That is the entire cost of being wrong, and it is paid
only on the steps that actually go wrong.
