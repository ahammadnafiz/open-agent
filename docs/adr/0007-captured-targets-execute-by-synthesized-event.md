# 7. Captured targets execute by synthesized event, and the classifier takes a third input

Date: 2026-09-20

## Status

Accepted. Refines [ADR 0004](./0004-vision-is-cloud-and-returns-an-index.md) and
[ADR 0005](./0005-coverage-is-a-gradient-not-a-boundary.md); leaves
[ADR 0001](./0001-irreversibility-is-upgrade-only.md) intact.

## Context

ADR 0005 put every surface in scope — "the agent works everywhere, with accuracy
and latency that vary by tier." ADR 0004 established that vision answers with an
index rather than a point, and concluded from that:

> ADR 0003's contract holds without a patch. Vision resolves a target, not a
> point. Nothing in the system emits a coordinate.

**That conclusion is true for tiers 1 and 2 and false for tiers 3 and 4.** The
gap is visible in the types, not in the prose.

`ElementRef` has exactly two cases, `.dom(handle:selector:label:)` and
`.ax(path:role:label:)`. `Executor` has exactly two implementations, one
dispatching `el.click()` against a BiDi `sharedId` and one calling
`AXUIElementPerformAction`. A target on a surface with neither — ghostty measured
at 12 AX nodes and **zero pressable**, a Figma canvas exposing nothing, an
Electron window at 4% labelled — resolves to an OCR line box or a detector box.
There is no handle to dispatch against and no accessibility action to perform.

So the honest status of tiers 3 and 4 today is **observable but not actionable**.
ADR 0005's coverage claim is a claim about perception that has been read as a
claim about execution. Nothing in the harness can act on what those tiers see.

A second gap, narrower and sharper. ADR 0005 states:

> An OCR box carries a label. A detector box carries a number. Both are
> identities a confirmation dialog can display and a denylist can inspect.

A denylist cannot inspect a number. `LabelDenylist` is a regex over label text,
and the tier 3b detector returns boxes **without labels** — that is the entire
reason it costs 9.71 ms instead of the 2,940 ms a local captioner would add.
Measured across 7 apps and 624 pressable elements, **74.2% are icon-only with no
text anywhere**. So on the modal element of the tier that exists specifically to
handle icons, `classify` has nothing to match and degrades to:

```
max(declared, .reversible) == declared
```

— the planner's declaration alone, which is the single-mechanism design ADR 0001
rejected by name, and which ADR 0003 cited as its reason for excluding these
surfaces in the first place.

Three options were weighed.

**A. Retreat to ADR 0003 for execution only.** Observe at any tier, but require
`.dom` or `.ax` to act. Canvas and terminal tasks fail cleanly. Preserves every
existing invariant and costs the coverage claim.

**B. Admit a coordinate-backed reference and rebuild the safety input for it.**
Keeps the coverage claim. Requires being honest that something, somewhere,
computes a point.

**C. Admit it and blanket-confirm every captured action.** Safe and unusable:
Chrome is 83% icon-only, so this asks the user about most clicks on most screens.

## Decision

**B.** Four parts, and the third is the one that makes it sound.

### 1. `ElementRef` gains a captured case

```swift
case captured(bbox: CGRect, label: String, provenance: Provenance)

public enum Provenance: String, Codable, Sendable {
    case ocrLine       // Vision RecognizeTextRequest — may span several controls
    case detectorBox   // tier 3b — one control, no label
    case visionMark    // tier 4 resolved a numbered mark to this box
}
```

### 2. The coordinate is an actuation detail, never an identity

`CapturedExecutor` synthesizes a `CGEvent` mouse click at the box centre. **That
is a coordinate and this document says so plainly** rather than maintaining that
none exists.

What ADR 0001 actually protects is preserved, and it is worth separating the
three things it protects:

| ADR 0001 requires | How a captured ref satisfies it |
|---|---|
| The denylist has something to inspect | The ref carries `label` — see part 3 |
| A confirmation can name what it will do | The dialog shows the label and the cropped region |
| A step is replayable and auditable | The log carries label, bbox, provenance, screenshot hash |

The point is computed **inside the executor, at act time, from the ref's bbox**.
It never appears in an `Action`, is never what a model emits, is never what the
planner declares, and is never the identity in a log. A model still answers with
an index; code still turns an identity into an effect. That separation is the
invariant, and it holds.

### 3. The classifier takes a third input, still upgrade-only

Captured labels come from three sources, in priority order: OCR text falling
inside the box; the label the vision model returns alongside its index; and,
failing both, empty. Tier 4's response type therefore changes from a bare index
to `{index, label}` — see [host-contract.md](../host-contract.md) § needs_eyes.

```swift
func classify(_ action: Action, target: Element?) -> Reversibility {
    let declared  = action.kind.isIrreversibleByDefault ? .irreversible : .reversible
    let bySource  = LabelDenylist.matches(target?.label) ? .irreversible : .reversible
    let byVision  = LabelDenylist.matches(target?.visionLabel) ? .irreversible : .reversible
    let unnamed   = target.isCapturedWithNoLabel ? .irreversible : .reversible

    return max(declared, bySource, byVision, unnamed)
}
```

**A vision-supplied label is attacker-influenced — it is read off pixels the page
controls — and admitting it here does not violate ADR 0001.** ADR 0001 forbids
any component *relaxing* the boundary. This input can only ever raise the
classification. An attacker who controls what the vision model reads can make the
agent ask the user **more** often, never less. That asymmetry is the whole reason
a model-derived string is admissible at this site when a model-derived *verdict*
is not.

### 4. An unnamed captured target is always irreversible

`.captured` with an empty label from every source confirms unconditionally. This
is option C, narrowed from "every icon" to "every icon that nothing could name" —
a much smaller set, because tier 4 labels what it selects.

## Consequences

**The coverage claim survives and is now true at the execution layer.** Terminals,
canvas editors, games and unlabelled Electron trees are reachable end to end, not
merely observable.

**Tier 3 OCR boxes are not directly actionable, and that is now an execution
constraint rather than a selection preference.** ADR 0005 established that
Vision returns *line* observations and that splitting them by gap is impossible —
inter-link and intra-link spacing are identical at every resolution. A merged
box's centre lands on an arbitrary one of the controls it spans, which as an
actuation is a confidently wrong click. Therefore a ref with `provenance ==
.ocrLine` is **never executed directly**; it may only feed tier 4's marks and be
re-emitted as `.visionMark`. `CapturedExecutor` rejects `.ocrLine` at runtime.

**Screen Recording permission becomes load-bearing for execution**, not only for
observation. A denied grant now removes capability rather than degrading it.

**The step log grows a screenshot hash for captured steps.** Without it a
captured step is unreplayable — the bbox means nothing without the frame it was
measured in. This is the audit property ADR 0003 worried about, paid for
explicitly rather than assumed away.

**Window state (Open Question Q6) is promoted from a testing nuisance to a
correctness prerequisite.** A synthesized click at a screen point lands on
whatever is topmost at that point. If the target window is occluded, the click
goes to the wrong application entirely — a failure mode tiers 1 and 2 structurally
cannot have, because they dispatch to an element rather than a location. The
harness must raise the window, verify it via `CGWindowListCopyWindowInfo`, and
refuse to execute a captured action when it cannot.

**This ADR is reasoned, not measured.** Every other ADR here rests on numbers
from this machine. This one rests on reading the types and finding a hole. The
open items it creates — captured-tier hit rate, how often vision returns a usable
label, how often the unnamed rule fires in practice — are Open Question Q7 and
need a `Probe` subcommand before any of it is trusted.
