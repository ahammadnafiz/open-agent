# 3. The coverage boundary is wherever a text tree exists

Date: 2026-09-18

## Status

**Superseded by [ADR 0005](./0005-coverage-is-a-gradient-not-a-boundary.md)**, 2026-09-18.

The principle below — that an action names its target by identity, never by
coordinate — survives unchanged. What was wrong was the claim that surfaces
without a text tree are unreachable. Measurement showed a text tree can be
*manufactured* from pixels, so coverage turned out to be a quality gradient
rather than a boundary. Kept for the record.

## Context

The agent is expected to handle "any task a real computer agent" would. That
phrasing invites an assumption worth writing down and killing: that the agent can
operate anywhere on screen, at the same speed, the way a person with a mouse can.

It cannot, and the reason is structural rather than a gap to be closed later.

Jev is text-only. It has no image input. It can select a target only from a list
of elements that something else has already produced. Two things produce such a
list on macOS:

- The DOM, via a browser's automation protocol. Measured: 3,684 nodes and 600+
  labelled actionable elements on a Wikipedia article.
- The accessibility tree, for applications that build one. Measured: Finder 174
  nodes / 33 actionable, Notes 44 / 12.

Where neither exists, there is nothing to select from. A `<canvas>` element is a
single DOM node with no interior. A GPU-rendered application — a terminal, a
game, a design tool — exposes no accessibility tree at all; measured on this
machine, ghostty and Cursor produced no AX window whatsoever.

So the fast path is not "fast where things go well and slow otherwise." It is
available exactly where a text tree exists, and absent everywhere else. The
question is what the agent does outside that region.

Two options were weighed explicitly.

**A guarded coordinate fallback.** When neither source yields the target, a vision
model returns a point and the agent synthesises a real click. This covers
everything. It also removes half the inputs to the safety classifier: the label
denylist matches on an element's label, and a coordinate has none, so
classification falls back to the planner's declared intent alone — the weaker of
the two mechanisms, and the one an attacker-influenced page can move. Steps
recorded as coordinates are also unreplayable and unauditable.

**Full cursor control.** Coordinates as a first-class action everywhere, with
human-like paths and timing. This is what most computer-use demos are. It
discards the semantic action model entirely, which means the confirmation
boundary, the step log, and Jev's role in selection all stop carrying meaning.
The result is a conventional vision agent that calls Jev for verification — a
legitimate product, and a different one.

## Decision

The agent operates only where a text tree exists. An `Action` always names its
target by identity.

Vision escalation resolves a **target**, not a point: given a screenshot and the
same candidate list the fast path saw, it returns which element to act on. It is
a better reader of the same list, not a different input modality.

Surfaces without a text tree — canvas, WebGL, games, GPU-rendered applications —
are **out of scope**, not "unsupported for now." A task that reaches one fails
cleanly and says why, rather than degrading into pixel-guessing.

## Consequences

Coverage is: every website, and applications that build an accessibility tree.
That is the large majority of what a person does on a Mac, and it includes every
task described when this project was scoped.

It is not: terminals, games, design tools, video editors, or any application
drawing its own interface. Electron is undetermined — the `AXManualAccessibility`
unlock is documented but was not conclusively tested here — and tracked as Open
Question Q2.

The safety model keeps both of its inputs everywhere the agent operates, because
everywhere it operates there is a labelled element to inspect. This is the whole
reason the boundary is drawn here and not somewhere more generous.

Every step remains replayable from the log, because every step names a target a
human can read.

Reversing this decision means revisiting ADR 0001, since the upgrade-only
classifier depends on a label existing. Adding coordinates is not an additive
change; it removes a mechanism.
