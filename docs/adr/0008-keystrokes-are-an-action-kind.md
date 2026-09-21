# 8. Keystrokes are an action kind, gated by what they will activate

Date: 2026-09-20

## Status

Accepted. Extends the closed set in [ADR 0001](./0001-irreversibility-is-upgrade-only.md).

**Key vocabulary widened 2026-09-21** by
[ADR 0014](./0014-the-action-set-is-foleys-discrete-half.md). The three-key set
below was closed on the reasoning that "an autocomplete suggestion is a clickable
element tiers 1–2 already resolve" — true of autocomplete, and false of anything
where an arrow is the primary verb. `Key` now carries sixteen cases. Everything
else in this document stands, including the part that matters most: `enter`
remains the only key routed through the submit denylist.

## Context

`ActionKind` is closed on purpose: `openApp, navigate, click, type, scroll,
focus, select, read, wait` plus the four irreversible kinds. SPEC.md § Boundaries
requires an explicit reversibility decision and a denylist review for any
addition, which is what this document is.

**The set cannot express a bare keystroke, and ordinary tasks need one.** Three
cases found while walking a mail-sending task end to end:

1. **Committing a token.** Outlook, Gmail, Linear, Slack and every other
   recipient or tag field turns typed text into a chip only on `Enter` or `Tab`.
   Without the keystroke the field *looks* filled, the agent proceeds, and the
   send goes nowhere or to a malformed address. Jev's `progressed` catches it on
   the next step — but the recovery ladder then has no rung that can fix it,
   because the fix is a key the action set cannot name.

2. **Dismissing transient UI.** An autocomplete dropdown or a popover covers the
   target. `Escape` closes it. Nothing else reliably does: clicking elsewhere may
   activate whatever is under the pointer.

3. **Leaving a field.** Some inputs validate or commit on blur, and `Tab` is the
   only guaranteed blur that does not activate something else.

The obvious workaround is to smuggle `"\n"` into `type`'s payload, and it should
be rejected. The payload is what the confirmation dialog shows the user
verbatim — SPEC.md § Boundaries, *"show the exact payload, never a summary"* —
and a trailing newline renders as nothing. The user would approve a string and
get a string plus a submission. An action must name what it does.

## Decision

Add one kind:

```swift
case pressKey    // payload is a Key raw value; target is the focused element

public enum Key: String, Codable, Sendable, CaseIterable {
    case enter, tab, escape
}
```

**Three keys, and the set is closed for the same reason `ActionKind` is.** Arrow
keys, editing keys and modifier combinations are deliberately excluded: no task
examined so far needs them, an autocomplete suggestion is a clickable element
that tiers 1–2 already resolve, and each addition is another effect the
classifier must reason about. Adding a fourth key is the same kind of decision as
this document, not a config change.

### Reversibility

`pressKey` is **reversible by default** and carries no inherent effect — its
effect is entirely determined by what receives it. So it is classified against
what it will activate, through the mechanism that already exists:

| Key | Classified against |
|---|---|
| `escape` | nothing — dismissal is reversible by construction |
| `tab` | nothing — moves focus, activates nothing |
| `enter` | the focused element's label, **and** its implicit submission target |

The second half of the `enter` row is the new part. `Enter` in a text field does
not activate that field; it activates the form's default submit button, whose
label the field does not carry. The observation script already computes a
`submit` flag per element; it now also carries the default submit button's label:

```javascript
submitLabel: (e.form && e.form.querySelector(
  'button:not([type=button]),[type=submit]'))?.innerText?.trim().slice(0, 80) || ''
```

That string becomes another upgrade-only input to `classify`. Pressing `Enter` in
Outlook's To-field with a `Send` button as the form default therefore classifies
`.irreversible` and asks — which is correct, and which no other mechanism in the
system would have caught.

### The residual risk, stated rather than hidden

**For `.ax` and `.captured` targets there is no computable submission target.**
The accessibility API has no notion of a form default, and a captured target has
no structure at all. `Enter` goes to the focused element and the application
decides what that means, which is not knowable before pressing it.

This is a genuine hole and it is narrower than it looks: `Enter` on a *native*
control that would send something requires focus already to be on that control,
in which case the focused element's own label is what the denylist inspects and
the existing rule fires. The uncovered case is a native text field whose parent
window sends on `Enter` with no such label reachable — measured examples not yet
collected. It is tracked as **Open Question Q8** and the mitigation, if it proves
real, is to classify `pressKey(.enter)` as irreversible for `.ax` targets by
default and accept the extra confirmations.

## Consequences

**Composing to a new recipient becomes expressible.** S1 itself does not need
this — a *reply* pre-populates the recipient, which is part of why it was chosen
as the native reference task. The gap appears the moment a task addresses someone
fresh, which is the first thing anyone will try after S1 passes, and it appears
in every web mail client, issue tracker and chat app rather than in one of them.

**One new constant**, `Constants.Safety.enterActivatesSubmit`, recording that
`enter` is the only key routed through the denylist. It lives in the file a human
reviews, per SPEC.md § Project Structure.

**`SafetyTests` grows a case per `Key` × denylist-matching `submitLabel`.** The
existing exhaustive test enumerates `ActionKind` × label; it now also enumerates
the submission-target input, since that is a path into `.irreversible` that no
other kind has.

**The confirmation dialog must render a keystroke honestly** — "Press Enter,
which will activate **Send**" rather than "Press Enter". Showing the key alone
repeats the exact failure that made payload-smuggling unacceptable.
