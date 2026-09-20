# ADR 0010 — The browser tier is one atomic indexed snapshot

**Status:** Accepted, 2026-09-20.
**Supersedes the sequencing in** [0006](./0006-native-first-sequencing.md) — browser
work is no longer deferred.
**Keeps** [0002](./0002-fast-path-reads-dom-not-accessibility.md) — the web fast
path still reads the DOM, and still over BiDi, not CDP.

---

## Context

[browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT,
Python) drives a browser with the same model this project uses. Its measured
result is worth taking seriously:

| | before | after |
|---|---|---|
| median task | 9.450 s | 7.092 s |
| **browser protocol calls** | **1,092** | **101** |
| TypeSafe requests | 22 | 17 |

The authors are careful about what that is: *"Three pairs are too few for a
strong statistical claim (two-sided sign-test p = 0.25)… a small controlled-input
comparison, not a broad agent benchmark."* Take the **architecture**, not the
number.

The architecture is three ideas:

1. **One browser call per observation.** A snapshot script reads every visible
   control — name, role, value, rect, state — atomically, instead of resolving
   hundreds of nodes one round trip at a time. This is where 1,092 → 101 comes
   from.
2. **A dynamic indexed action space.** The model is shown a numbered table of
   only the operations and targets that exist right now, and answers with an
   index.
3. **Target validation before acting.** Geometry and occlusion are re-checked
   against the snapshot; a control that has moved or been covered is refused
   rather than clicked.

## Decision

**Adopt all three ideas. Adopt none of the process.**

The browser tier is a Swift `BiDiSource` that evaluates one snapshot script per
observation and returns `Element`s, plus a `BiDiExecutor` that acts on them.
`jev-ultrafast`'s snapshot design is the reference; the implementation is ours.

### What we deliberately did not take

- **Python, `uv`, and a browser library.** `SPEC.md` § Boundaries: *"Adding a
  dependency. The current count is zero outside the standard library, and that
  is a feature."* Running their agent as a sidecar would add a language runtime
  to a Swift binary to obtain a JavaScript string and a WebSocket client, both of
  which we already have.
- **Their second model.** `jev-ultrafast` calls `inception/mercury-2.5` through
  OpenRouter for text generation. [ADR 0009](./0009-the-agent-is-a-skill-and-the-host-model-plans.md)
  removed exactly that role and forbids `OpenRouterClient.swift`. The host agent
  already composes prose. One host model, one judgment model: that is the whole
  shape.
- **Their loop.** It has `DONE` and `BLOCKED` and **no irreversible-action
  gate**. Delegating web steps to it would put `publish`, `send` and `purchase`
  — the actions that most need the boundary — outside it. Our loop keeps the
  gate, the budgets, the batteries and the approval sheet; the browser tier only
  ever supplies perception and actuation.
- **CDP.** They use `Input.dispatchMouseEvent`. ADR 0002 chose BiDi on measured
  latency and we have no measurement that overturns it, so the protocol stands.

### What this costs, stated plainly

Their snapshot clicks by computing a point from the selected element's own
`getBoundingClientRect()`. Ours does too, and that is **not** a violation of
ADR 0001: the *identity* is the element, and the point is derived at act time
from an already-selected, already-gated target. That is the
[ADR 0007](./0007-captured-targets-execute-by-synthesized-event.md) exception,
and it is why `BiDiExecutor` dispatches through the element handle where it can
and only falls back to a point where it cannot.

Their stated limits become ours where we copy them: *"Shadow roots, frames,
canvas, uploads, pop-up tabs, nested scrolling, and arbitrary keyboard widgets"*
are out of scope, and the DOM reader *"does not implement the full
accessible-name algorithm."* One difference: `element-sources.md` already
specified piercing **open** shadow roots, and our snapshot keeps that.

## Consequences

- `Constants.Jev.maxCandidates` (255) and their cap (250) agree closely enough
  that no new ceiling is needed. The filter still throws rather than truncating.
- Their ids are already `e1`, `e2`, … — the same namespace this project chose
  independently, for the same reason.
- ADR 0006's *reason* survives: native shipped first, and it did. What is
  superseded is only the claim that browser work stays off the path.

## Forbidden by this decision

- Adding a Python sidecar, or any language runtime, to reach the browser.
- Calling a second generative model from the binary. The host writes prose.
- Executing a web action that has not passed `Irreversibility.classify`.
- Switching the web fast path to CDP without a measurement that beats BiDi.

## Attribution

The snapshot design — atomic read, indexed action space, guard-based staleness
detection — is from `browser-use/jev-ultrafast`, MIT licensed. The JavaScript in
`Sources/Harness/Perception/Resources/snapshot.js` is our implementation of that
design.
