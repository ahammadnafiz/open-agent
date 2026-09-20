# 1. Irreversibility is upgrade-only

Date: 2026-09-18

## Status

Accepted

## Context

Every irreversible action on the web is mechanically a click. Publishing a post,
sending an email, and deleting an account are all `click` on a button. The verb
an agent emits therefore carries no information about whether the effect can be
undone.

We need the agent to ask before irreversible actions and not ask before
reversible ones. Three mechanisms could decide which is which:

1. The planner declares its own intent (`kind: publish`).
2. A deterministic rule inspects the target element's label and role.
3. A model judges the effect of activating the element.

Option 3 was rejected earlier: a probabilistic judgment on this boundary is
non-deterministic across identical inputs and can be moved by text on the page
being operated on, which is attacker-influenced by definition.

Option 1 alone moves the boundary from one model to another. A planner reading a
page that labels its submit button "Cancel" will declare the wrong intent, and
nothing catches it.

Option 2 alone produces false positives ("Submit" on a search form) and misses
anything whose label is unusual or non-English.

## Decision

Both 1 and 2 run, and they can only ever make an action *more* restricted.

The effective classification is the maximum of what the planner declared and
what the deterministic label rule found. A match on either marks the action
irreversible and requires confirmation.

No component may downgrade an action from irreversible to reversible. Not the
planner, not the risk model, not anything derived from page content.

A corollary, which constrains the action type itself: an action must name its
target by identity, never by screen coordinate. Neither mechanism above can run
against `click(847, 203)` — the planner cannot declare an intent it cannot
describe, and the label rule has no label to inspect. Nobody, human or machine,
can tell whether clicking a pixel publishes a post or scrolls a list. The
closed verb set and the element-reference type follow from this, and any change
that admits coordinates into an action reopens this decision.

## Consequences

The safety boundary no longer depends on any single judgment being correct. A
planner mistake is caught by a rule too simple to be argued with; an unusual
label is caught by the planner understanding intent. Both must fail silently and
simultaneously for an unconfirmed irreversible action to occur.

We accept false-positive confirmations. A search form that says "Submit" will
ask once. This is the correct direction to be wrong in.

The label rule needs per-locale and per-app maintenance, and will not cover an
app whose buttons are icons with no accessible label. Those cases fall to the
planner's declared intent alone, which is weaker — such targets should be
treated as escalation candidates rather than fast-path actions.
