# 5. Coverage is a gradient, not a boundary

Date: 2026-09-18

## Status

Accepted. Supersedes [ADR 0003](./0003-coverage-boundary-is-where-text-exists.md).

**Corrected 2026-09-20 by [ADR 0007](./0007-captured-targets-execute-by-synthesized-event.md).**
The coverage argument below is sound, and two of its consequences were wrong.
This ADR established that a candidate list can be manufactured from pixels — a
claim about *perception* — and then asserted that the safety model and the
no-coordinate contract were unaffected, which are claims about *execution* and
did not follow. At the time this was written no `ElementRef` case and no
`Executor` existed for a target with no element tree, so tiers 3 and 4 were
observable but not actionable, and the denylist had nothing to match on an
unlabelled icon. ADR 0007 closes both. The two paragraphs are marked inline.

## Context

ADR 0003 drew a hard line: the agent operates where a text tree already exists,
and canvas, games, and GPU-rendered applications are out of scope. That line was
drawn from one true observation — a System One model is text-only and can only
select from a list — and one false inference, that nothing could produce such a
list from pixels.

Four things were then measured, and together they move the line.

**A text tree can be manufactured.** Apple's Vision framework returns text with
bounding boxes from any screenshot, on-device, in 23 ms (`.fast`) to 368 ms
(`.accurate`) on a full Retina screen. Capture via ScreenCaptureKit costs 7–17 ms
and works on occluded and minimized windows. That is a labelled candidate list
from arbitrary pixels, well inside the step budget.

**Accessibility trees can be forced.** A single read of the application element
makes Chromium and Gecko build their web trees; `AXManualAccessibility` is
settable on Electron applications (confirmed on Cursor, rejected by Chrome,
Safari, Zen and Finder, which is the expected Electron-only signature). See the
Correction in ADR 0002.

**Icons can be detected cheaply.** OmniParser's detector exported to CoreML runs
at 9.71 ms at imgsz 640 and 57.75 ms at 1280 on the Apple Neural Engine. It
returns boxes without labels — which is exactly enough for the next point.

**Vision can answer with an index rather than a point.** Numbered boxes drawn
over candidates turn grounding into selection. Measured across four models,
12 intents: **100% on text-labelled targets, 71% on icon-only targets**, with the
`0 = none fit` escape absorbing most failures as refusals rather than wrong
clicks. See ADR 0004.

None of these removes the requirement that an action name its target by identity.
An OCR box carries a label. A detector box carries a number. Both are identities
a confirmation dialog can display and a denylist can inspect.

> **Corrected — ADR 0007.** The last sentence is wrong about the detector box. A
> denylist is a regex over label text; a number is not something it can inspect,
> and the tier 3b detector returns boxes *without* labels by design — that is why
> it costs 9.71 ms rather than the 2,940 ms a captioner would add. Since 74.2% of
> pressable elements are icon-only, this was not an edge case. ADR 0007 supplies
> the missing label by having tier 4 return `{index, label}`.

## Decision

There is no coverage boundary. There is a quality gradient, and the agent works
everywhere on it, with accuracy and latency that vary by tier.

| Tier | Source | What it yields | Measured |
|---|---|---|---|
| 1 | DOM via WebDriver BiDi | label, role, state | **81% hit, 69% gated, 100% gate precision, 552 ms** |
| 2 | Accessibility tree | label, role, state, real actions | **100% hit, 100% gated, 100% precision, 473 ms** |
| 3 | Screen capture + Vision OCR | label, bbox | see the caveat below |
| 4 | Vision model + numbered marks | index | **83% — 100% text, 71% icon** |

Each step selects the highest tier available for its target and falls through on
failure. A task is never refused for being on the wrong surface; it is answered
more slowly and less accurately as it descends the gradient.

## Consequences

**The product claim changes.** It is no longer "works in browsers and Cocoa
apps." It is "works anywhere, best where the application tells us what it is."
Terminals, canvas editors, and games are reachable, at tier 3 or 4 speed and
accuracy.

**Tier 3 is not usable as it stands, and the reason is specific.** Apple's Vision
OCR returns *line* observations, not element observations: horizontally adjacent
controls merge into one box. Measured on real pages, `"Donate Create account Log
in"` came back as a single observation spanning three separate links, and Hacker
News's entire navigation bar became one candidate. A merged box has a label that
looks plausible and a centre point that lands on an arbitrary one of the controls
it spans — a confidently wrong click, which is the worst failure available.

**Splitting those lines by horizontal gap was attempted and does not work.**
Vision's per-word boxes are real glyph metrics, not interpolations — `iiii`
measures 77 px against `WWWW` at 257 px. But the gap between two separate links
equals the gap between two words inside one link, at every capture resolution:
2/2 px at DPR 1, 3/3 at DPR 2, 6/5 at DPR 3. Pages render navigation at word
spacing, and raising resolution scales both gaps equally. There is no threshold
to find.

**Therefore tier 3 is not a standalone selection tier.** Text alone cannot
delimit controls. Control boundaries must come from a model that recognises
controls — the tier 3b detector — with OCR text assigned to the boxes it
produces. Until that exists, tier 3's output feeds tier 4's numbered marks, where
a vision model disambiguates visually, rather than being selected from directly.

**Use `.accurate`, not `.fast`.** Measured on the same pages, `.fast` produced
`Cr8ate`, `R&ad`, `Mlcrosoft`, `Hirln`; `.accurate` produced none of those. The
cost is 368 ms against 92 ms, which the budget absorbs. Set
`minimumTextHeight = 0` — the default of 1/32 of image height silently returns
zero observations on a Retina screenshot.

**The safety model is unaffected.** Every tier produces a labelled identity, so
the upgrade-only classifier keeps both of its inputs everywhere the agent
operates, and no path emits a coordinate.

> **Corrected — ADR 0007.** Neither half held. An unlabelled icon is not a
> labelled identity, so the classifier lost an input on the modal element of the
> tiers this ADR added. And a target with no element tree cannot be actuated by
> dispatch, so `CapturedExecutor` computes a click point from the target's own
> bounds — a coordinate, downstream of every gate, never present in an `Action`.
> The invariant that survives is narrower and worth stating exactly: **an
> identity is never a coordinate, and no model ever emits one.**

**Two prerequisites are now load-bearing and were not in the original design.**
Tier 3 needs Screen Recording permission. Tiers 2 and 3 need the target window
to be on the current Space and not minimized — a minimized window observes as
*empty*, not as an error, which would otherwise read to the agent as "nothing
actionable here." The harness must raise and verify the window before observing,
and fail loudly when it cannot.
