# ADR 0014 — The action set is Foley's discrete half

**Status:** Accepted, 2026-09-21.
**Extends** [0001](./0001-irreversibility-is-upgrade-only.md) by finding the
line it draws, and [0008](./0008-keystrokes-are-an-action-kind.md) by widening
the key vocabulary its reasoning had closed.

---

## Context

The action set was fourteen kinds. Asked whether the agent could edit video, the
answer was no — and the reason turned out to be more interesting than the
question.

Foley, Wallace & Chan (1984) decompose all graphical interaction into six tasks:
**select, position, orient, path, quantify and text entry.** Every shipping
computer-use action space is a re-derivation of that list. Anthropic's computer
use tool and OpenAI's CUA both cover all six, by way of `left_click_drag` /
`drag` and `mouse_move` / `move`.

Mapping the fourteen kinds onto Foley showed the gap was not scattered:

| Foley task | open-agent | covered |
|---|---|---|
| select | `click`, `select`, `focus` | yes |
| text entry | `type`, `pressKey` | yes |
| quantify | `scroll` | by wheel only |
| **position** | — | **no** |
| **path** | — | **no** |

*Position* and *path* are exactly the two tasks whose target is **continuous**.
And ADR 0001 says, in `Action.swift`:

> *"A raw coordinate cannot be risk-gated: nobody can tell whether clicking
> (847,203) publishes a post or scrolls a list."*

So the missing verbs were not an oversight. The set was already, precisely,
Foley's discrete half — ADR 0001 drawing its boundary along the discrete /
continuous split, and doing it so cleanly that nobody had had to name it.

Which reframes the question. Not *"can we add drag"*, but *"can a drag carry an
identity that is not a coordinate"*. Sometimes it can:

- *drag `report.pdf` onto `Archive`* — both ends are named elements.
- *drag the playhead to 00:01:23:04* — the destination is a coordinate **by
  nature**, and no name for it exists.

That is a real split, and it is why file management is reachable and video
editing is not.

## Decision

**Five kinds, taking the set from fourteen to nineteen.**

Four are discrete and name exactly one element, so they sit inside ADR 0001
unchanged — `doubleClick`, `rightClick`, `hover`, `setValue`.

`setValue` is the one that repays the most. A slider, stepper or range input
carries a settable value, so *quantify* becomes expressible **without a drag at
all**: "set zoom to 150" names an element and a number rather than a pixel to
drag to, which is the difference between an action a confirmation can describe
and one it cannot. A large share of what would otherwise need drag is really
this.

The fifth is `drag`, and it is admitted on one condition: **both endpoints are
named elements.** A destination that is a point is refused, because it could not
be shown in a confirmation, matched by the denylist, or read back out of a log —
which is the whole of ADR 0001.

`drag` is **irreversible by default**, alone among the pointer verbs. A click
that lands wrong selects the wrong thing and the screen says so. A drag that
lands wrong has already moved something, and where it came from is not written
anywhere the agent can read back. Dropping a file onto Trash is a `delete`
wearing a different verb.

Which is why the destination becomes the **sixth input to
`Irreversibility.classify`**. Every existing input inspects the element being
acted on, and for a drag that element is innocent — a file, a row, a card. The
classifier could not see the drop target at all, and the drop target is the half
that decides whether the action was destructive.

**The key vocabulary widens from three to sixteen.** ADR 0008 excluded arrows
and editing keys on the grounds that "an autocomplete suggestion is a clickable
element tiers 1–2 already resolve". That is true of autocomplete and false of
everything where an arrow is the primary verb — a list the snapshot never
collects, a native table, a scrubber. The reasoning held for the case it was
written about and did not generalise.

The *gated* set does not widen with it: `enter` remains the only key routed
through the submit denylist, because an arrow activates nothing and gating it
would teach people the sheet is noise.

Combinations are added as **named meanings** — `selectAll`, `undo` — not as
modifier+key pairs a planner assembles. A closed set of meanings stays
reviewable; `cmd+shift+<anything>` does not.

## Verified

Live runs against an instrumented page, where each verb writes its own verdict
and a handler that never fires leaves `PENDING` on screen.

**Reproducibly verified — `doubleClick`, `rightClick`, `hover`, `setValue`:**

```
doubleClick OK          real dblclick, not two clicks
rightClick OK           contextmenu fired
hover OK                mouseenter with NO mousedown
setValue OK value=73    input event fired, value landed exactly
```

`hover OK` rather than `hover BUT PRESSED` is the one worth naming: the pointer
arrived without pressing, which is the whole distinction between that verb and
`click`.

**`drag` — verified once, not reproduced. Open.**

One run produced `drag OK moves=24`, on the page's own counter, with 24 exactly
`Constants.Execution.dragSteps`. That page requires at least three intermediate
moves and reports `TELEPORTED` otherwise, so the number is real: a press at the
source and a release at the destination with nothing between is a gesture most
pages never recognise as a drag at all.

Subsequent runs of the same plan did not reproduce it. On those, the BiDi
payload on the wire was confirmed correct, `input.performActions` returned
success, and the page's `document`-level `mousedown`/`mousemove`/`mouseup`
listeners recorded **nothing** — while a single-action `pointerMove` from
`hover` was delivered to the same document in the same run.

Ruled out, each by test: the coordinates (identical across two implementations,
and landing inside both elements); `pause` and per-move `duration`; occlusion
and viewport clamping; needing a prior input event; stranded WebDriver input
state (a completely fresh browser session behaves the same); and the executor
code itself, which was reverted to the exact revision that produced the passing
run and still did not reproduce it.

The one correlation left standing is that the passing run had `drag` as the
**last** step after three real click sequences, and every failing run had it as
the first pointer-with-button action after a navigation. That is a correlation,
not a cause, and it is written down here rather than guessed at.

`input.releaseActions` is now issued either side of a drag regardless. It did
not fix this, and it is correct on its own terms — the wire equivalent of the
`defer` that guarantees a released button in `PointerSynthesis`.

**The native (AX) drag path is unaffected by any of this** and carries its own
release guarantee.

## Consequences

- `Action` gains `destination: ElementRef?`, populated only for `drag`. A second
  ref, never a point.
- `PlanStep` gains `destination: String?` — a name, like `target`, because the
  plan is written before the screen is observed.
- The destination resolves by **exact name** against the live element list
  rather than through Jev. Same reasoning as `uniqueMatch(named:)`: a question
  with one answer is not worth a model call, and a drop target the screen cannot
  name unambiguously is not one to guess at. No match is `needs_plan`.
- The confirmation sheet shows **both ends**. "Move report.pdf" is a sentence
  someone approves without knowing whether it was filed or thrown away.
- **A known limitation, left in deliberately.** `validate` calls
  `scrollIntoView`, so validating a drag's destination can move its source, and
  on a list taller than the viewport the press can land at coordinates that now
  belong to a different row. A version measuring both ends in one non-scrolling
  pass was written to close that, and produced a drag the page never received at
  all — so the verified path is kept and the limitation documented. A
  theoretical fix that breaks a working path is not a fix.
- `AXExecutor` gains a pointer, through a new `PointerSynthesis` sibling to
  `KeySynthesis`. The accessibility API has no second click, secondary click,
  hover or drag — `AXPress` is a single primary press — so the four verbs are
  synthesized at the HID layer, always against a frame read from a **named**
  element. The point exists inside the executor and never reaches the log.
- `setValue` reads back what it wrote, on both tiers. A control that clamps,
  rounds or ignores a write reports success and holds something else; the read
  back is the same lie `type` already learned not to tell.

## Forbidden by this decision

- A `drag` whose destination is a coordinate, and any verb that positions a
  pointer at a bare point — `moveTo(x, y)`, freehand path, timeline scrub. The
  CGEvent script outside the gated set is the right home for those: invoked
  deliberately by a person, never emitted by a planner.
- Clipboard keys. `copy` and `paste` move content the confirmation cannot
  display, and an action whose payload is invisible breaks the one property
  every other action holds — that a human sees exactly what is about to happen.
  `type` covers text entry and shows its payload verbatim.
- Widening `gatedKeys` alongside the vocabulary. Gating a key that activates
  nothing trains people to dismiss the sheet.
