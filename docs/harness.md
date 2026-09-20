# The Harness

The core loop, end to end. Types, contracts, sequencing, and the reasoning
behind the shape. Terms are defined in [../CONTEXT.md](../CONTEXT.md).

---

## 1. The shape in one page

```
open-agent run "<task>" --plan plan.json
│
├─ Budget()                      40 steps / 90s machine / 3 escalations / 2 replans / $0.25
├─ Plan                          from the HOST, ONCE, before the loop starts.
│                                A hypothesis about the route, not a script.
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
   │              wrongContext is this a DIFFERENT account/doc than the task named
   │                           (only asked when task_context is non-empty)
   │              target       Choice over candidate ids  ← the selection
   │              sufficient   is this element list enough, or do we need eyes
   │              risk*        intent-level risk nouls
   │
   │  ── ROUTE ─────────────────────────────────────────────────
   ├─ if verdict.taskDone           → finish(.succeeded)
   ├─ if verdict.blocked  ≥ T       → surface to user, STOP. Never retried.
   ├─ if verdict.looping  ≥ T       → escalate once, then STOP.
   ├─ if verdict.wrongContext ≥ T   → RecoveryLadder.next()  right screen, wrong one
   ├─ if ¬verdict.progressed        → RecoveryLadder.next()
   ├─ if verdict.sufficient < T
   │     ∨ verdict.target.confidence < T
   │                                 → RETURN needs_eyes, exit.
   │                                   Host reads the marked screenshot and
   │                                   resumes with an index. One tool call.
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
    case openApp, navigate, click, type, pressKey, scroll, focus, select, read, wait
    // Irreversible by default — always confirmed, never auto-executed
    case publish, send, delete, purchase

    var isIrreversibleByDefault: Bool {
        switch self {
        case .publish, .send, .delete, .purchase: true
        default: false
        }
    }
}

/// Keys `pressKey` may send. Closed for the same reason `ActionKind` is —
/// see ADR 0008. Arrow and editing keys are deliberately absent: an
/// autocomplete suggestion is a clickable element tiers 1–2 already resolve.
///
/// `enter` is the only key with an effect the denylist must reason about, and
/// it is classified against the focused element's *implicit submission target*,
/// not the field itself. A newline smuggled into `type`'s payload is not an
/// acceptable substitute: the confirmation shows the payload verbatim and a
/// trailing newline renders as nothing.
public enum Key: String, Codable, Sendable, CaseIterable {
    case enter, tab, escape
}

/// Identity of a UI element. An identity is never a coordinate — see ADR 0001.
///
/// A raw coordinate cannot be risk-gated: nobody can tell whether clicking
/// (847,203) publishes a post or scrolls a list. Every case below carries enough
/// identity to be named in a confirmation dialog, matched by the denylist, and
/// written to a log a human can read months later.
///
/// `.captured` is the one case whose *actuation* is a point, computed inside the
/// executor from `bbox` at act time — see ADR 0007. The point is never part of
/// the ref, never what a model emits, and never what the log records as the
/// identity. The distinction is not cosmetic: it is what keeps the denylist and
/// the confirmation dialog functional on surfaces that expose no element tree.
public enum ElementRef: Codable, Sendable, Hashable {
    /// Web. `handle` is a BiDi script.NodeRemoteValue sharedId; `selector` is a
    /// human-readable fallback used for logging and re-resolution after reload.
    case dom(handle: String, selector: String, label: String, submitLabel: String)
    /// Native. `path` is the index chain from the window root, which is stable
    /// only within one observation — always re-observe before acting.
    case ax(path: [Int], role: String, label: String)
    /// Tier 3/4. No element tree exists for this target. `label` may be empty,
    /// in which case `classify` returns `.irreversible` unconditionally.
    /// A ref with `provenance == .ocrLine` is never executed — see ADR 0007.
    case captured(bbox: CGRect, label: String, provenance: Provenance)

    var label: String { … }
}

public enum Provenance: String, Codable, Sendable {
    case ocrLine       // Vision RecognizeTextRequest — may span several controls
    case detectorBox   // tier 3b — one control, no label
    case visionMark    // tier 4 resolved a numbered mark to this box
}

public struct Action: Codable, Sendable {
    public let kind: ActionKind
    public let target: ElementRef?      // nil only for openApp / navigate / wait
    public let payload: String?         // text to type, url, app name, or Key raw value
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

**Rung 0 is skipped when the screen moved.** Jev distinguishes two failures that
the rung order alone conflates, and retrying the second is guaranteed waste:

| `progressed` | `unchanged` | What happened | Rung |
|---|---|---|---|
| low | **high** | the action did nothing — a click genuinely missed | 0, retry |
| low | **low** | the screen moved, just not toward the goal | **straight to 2** |

The second row is what "the screen is new" looks like from inside the loop: an
unexpected dialog, the wrong account, a redirect. Retrying reproduces it. The
fixtures separate cleanly — 0.84/0.91 on genuine no-ops against 0.02–0.06
otherwise — so the branch is cheap and well supported.

```swift
actor RecoveryLadder {
    private var rungByStep: [Int: Int] = [:]

    func next(for stepIndex: Int, verdict: StepVerdict, budget: inout Budget) -> Recovery {
        var rung = (rungByStep[stepIndex] ?? -1) + 1

        // The screen changed and did not help. Retrying reproduces it exactly.
        if rung == 0, verdict.unchanged < Constants.Jev.unchanged { rung = 2 }

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

    // Whatever the source named this element. Empty for an unlabelled icon.
    let bySource = LabelDenylist.matches(target?.label)

    // What tier 4 called the element it selected. Attacker-influenced — it is
    // read off pixels — and admissible anyway, because it can only ever RAISE
    // the classification. See ADR 0007.
    let byVision = LabelDenylist.matches(target?.visionLabel)

    // What `Enter` would actually activate. A text field does not carry the
    // label of the button its form submits to. See ADR 0008.
    let bySubmit = action.kind == .pressKey && action.payload == Key.enter.rawValue
        ? LabelDenylist.matches(target?.submitLabel) : false

    // A captured target nothing could name. Rare, and the right way to be wrong.
    let unnamed = target?.isCapturedWithNoLabel ?? false

    return max(declared, .from(bySource), .from(byVision), .from(bySubmit), .from(unnamed))
}
```

`LabelDenylist` is a compiled regex over the target's label and role, plus a
`role == "submit"` check. It exists because **the verb never tells you what a
click does** — publishing a tweet is `click("Post")`, and `click` is reversible.
The five inputs are independent; **all** of them must fail silently and
simultaneously for an unconfirmed irreversible action to occur.

Every input is upgrade-only, and that is what lets two of them accept
model-derived and page-derived strings. ADR 0001 forbids a component *relaxing*
the boundary. An attacker who controls what the vision model reads, or what a
form's submit button says, can make the agent ask the user **more** often —
never less.

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
`browsingContext.navigate` with `wait: "complete"` for navigation, and
`input.performActions` with the W3C key code (`` enter, `` tab,
`` escape) for `pressKey`.

**AX** — `AXUIElementPerformAction(el, kAXPressAction)` for click,
`AXUIElementSetAttributeValue(el, kAXValueAttribute, …)` for typing where
supported, falling back to `CGEvent` key synthesis with the element focused.
`pressKey` is `CGEvent` with the element focused first — there is no AX action
for a keystroke.

**Captured** — `CGEvent` mouse down/up at the centre of `bbox`, in screen
coordinates. Three preconditions, each enforced rather than assumed:

```swift
func execute(_ action: Action) async throws -> ExecutionResult {
    guard case .captured(let bbox, _, let provenance) = action.target else { … }

    // 1. An OCR line box may span several controls, and its centre lands on an
    //    arbitrary one of them. ADR 0005 measured that splitting by gap is
    //    impossible. This is the worst failure available, so it is refused.
    guard provenance != .ocrLine else { throw ExecutionError.ocrLineNotActionable }

    // 2. A point click lands on whatever is topmost THERE. Unlike tiers 1–2,
    //    which dispatch to an element, this can hit another application
    //    entirely. Q6 is a correctness prerequisite here, not a nuisance.
    guard try await window.raiseAndVerifyOnScreen() else { throw ExecutionError.windowNotVisible }

    // 3. The bbox is meaningless without the frame it was measured in. The log
    //    carries the hash or the step is unreplayable — ADR 0007.
    try log.attach(screenshotHash: observation.frameHash)
    …
}
```

**Every `ElementRef` case has exactly one executor, and `Executor.for(ref)` is
total.** A ref the harness can produce but not act on is the defect ADR 0007 was
written to close; if a case is ever added, this switch is where it must be
handled rather than defaulted.

### 7.1 Narration is the same call as execution

The cursor overlay draws the target a moment before the executor fires. The
ordering matters — it is what gives the user time to object — but the *coupling*
matters more:

```swift
// The only supported shape.
let result = try await hud.narrating(action, target: element) {
    try await Executor.for(source).execute(action)
}
```

Not `overlay.move(…)` followed by `executor.execute(…)`. Two calls can drift, and
an overlay that rings element X while the executor acts on element Y is worse
than no overlay at all: it is a confident, legible lie about what just happened,
and the user has been trained by every correct step before it to believe it.
Wrapping execution makes the two structurally inseparable.

The overlay reaches the loop through `HUDBridge`, so `Harness` never imports
AppKit and the headless library stays headless.

**Two cursors at tiers 3–4.** `CapturedExecutor` posts a real `CGEvent` to
`.cghidEventTap`, which moves the user's actual pointer. Tiers 1 and 2 move no
pointer at all — they dispatch to the element. So on captured steps the overlay
cursor and the system cursor both arrive at the same place, which reads as a
glitch. On `.captured`, keep the ring and the narration chip and **hide the
overlay cursor**: the real pointer is genuinely doing the work, and saying so is
more honest than drawing a second arrow over it. Tracked as Open Question Q9.

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
    private let session: Session        // run/resume state, on disk between invocations
    private let hud: HUDBridge          // @MainActor: the overlay, and the approval sheet
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
| 0 | — | plan (host, before `run` is invoked) | — | — | host turn |
| 1 | ax | `openApp` Zen (agent profile, `--remote-debugging-port`) | — | auto | ~1500 |
| 2 | bidi | `navigate` x.com/ahammad_nafiz | progressed 0.97 | auto | ~800 |
| 3 | bidi | `click` compose | progressed 0.95, sufficient 0.93 | auto | ~410 |
| 4 | — | post body arrives in the plan payload, written by the host | — | — | 0 |
| 5 | bidi | `type` post body | progressed 0.97 | auto | ~600 |
| 6 | bidi | `publish` Post button | progressed 0.95 | **CONFIRM** | human |
| 7 | bidi | — | taskDone 0.95 | — | ~410 |

Machine time ≈ 6.3 s inside `open-agent`. Jev cost ≈ 6 × $0.000027 ≈ **$0.00016**,
which is the entire metered cost — planning and composition were host turns.
No callback fired. One confirmation, showing the exact post text.

The failure path is the more instructive one. If step 3's click does nothing,
step 4's batch returns `progressed 0.03, unchanged 0.84`. The ladder retries the
click once. Still unchanged, so it escalates: one screenshot, one `needs_eyes`
return, one host turn to look at it, one `resume`. That is the entire cost of
being wrong — two tool calls rather than a cent — and it is paid
only on the steps that actually go wrong.
