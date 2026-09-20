# 4. Vision escalation is cloud, and returns an index

Date: 2026-09-18

## Status

Accepted

## Context

The fast path resolves a target from a text list — DOM, accessibility tree, or
OCR. Some steps it cannot resolve: an icon with no label, a canvas control, a
target absent from the list entirely. Those steps escalate to a model that can
see the screen.

Two options were available, and the second looked attractive enough to research
properly.

**A local GUI grounding model.** A generation of small open models now does
element grounding well. Holo2-4B reaches 57.2 on ScreenSpot-Pro, beating
UI-TARS-72B at 38.1; UI-TARS-1.5-7B ships as a 4.87 GB Apache-2.0 MLX build.
Running one on-device would remove the network round trip, the per-escalation
cost, and the privacy exposure of sending a window image to a third party.

The latency evidence killed it. Only two hardware-attributed measurements exist
anywhere in this literature:

- OmniParser V2: 0.6 s on an A100, 0.8 s on a 4090.
- Holo3.1 on a MacBook M4 Pro: **3.6–5.5 requests per minute — 11 to 17 seconds
  per call.**

No Core ML conversion exists for any GUI grounding model, so nobody has done the
work that would make one fast on Apple silicon. Weights are also not the memory
budget: screenshot tokens have been measured at ≥85.4% of all tokens in these
models, and first-token latency is vision-encode bound.

A cloud frontier model answers the same question in 2–4 seconds. The local option
is roughly four times slower than the thing it was supposed to optimise.

**A cloud vision model.** 2–4 s, vision-capable, no weights to ship.

Four candidates were measured on the same 12 intents against one screenshot
carrying 23 numbered boxes — 8 icon-only, 15 text-labelled:

| Model | icon-only | text | total | latency | $/call |
|---|---|---|---|---|---|
| `google/gemini-3.5-flash-lite` | 4/7 (57%) | 5/5 | 9/12 (75%) | 3,349 ms | $0.00039 |
| **`google/gemini-3.8-flash`** | **5/7 (71%)** | 5/5 | **10/12 (83%)** | 4,802 ms | **$0.00096** |
| `google/gemini-2.5-pro` | 5/7 (71%) | 5/5 | 10/12 (83%) | 8,956 ms | $0.00443 |
| `anthropic/claude-sonnet-5` | 5/7 (71%) | 5/5 | 10/12 (83%) | 3,890 ms | $0.00989 |

Three architecturally unrelated models tie at exactly 5/7 and fail on the same
two icons, which is the signature of an unidentifiable test fixture rather than a
model ceiling — the two were a "gear" drawn as concentric circles and a
"bookmark" drawn as a circle with a line through it. Real application icons
should score higher.

The published grounding benchmarks predicted the opposite ordering. ScreenSpot-Pro
places Claude Computer Use at 17.1 and Gemini 3 Pro at 72.7. That benchmark
measures *coordinate regression from an instruction*; Set-of-Marks asks a
selection question instead, which plays to general visual reasoning. **The
ScreenSpot ranking does not transfer to this architecture**, and the model choice
was made on the measurement above rather than on it.

## Decision

Vision escalation calls **`google/gemini-3.8-flash`** via OpenRouter. No local
grounding model, no MLX, no model weights shipped with the application.

`gemini-3.5-flash-lite` is the only candidate below the ceiling — 57% against 71%
on icon-only targets, a 14-point gap on precisely the class of element tier 4
exists to handle, since tiers 1–3 already resolve anything text-labelled. The
extra cost is $0.0006 per escalation, or **$0.003 per task** at three
escalations. `gemini-2.5-pro` is dominated outright: same accuracy, slowest,
4.6× the cost. `claude-sonnet-5` matches on accuracy and is ~900 ms faster, which
is inside the noise on n=12 over a high-latency link, at 10× the price.

The escalation request carries **a screenshot with the candidate elements drawn
on it as numbered boxes**, together with the numbered list as text. The model
returns **the number of the element to act on**, not a coordinate.

This is the Set-of-Marks technique, and adopting it follows directly from the
choice of a cloud model — a frontier model can reliably read overlaid numerals,
which is what makes an index answer possible. It is also measurably better than
asking for a coordinate: pairing a detector with numbered marks moved GPT-4V from
16.2% to 73.0% on ScreenSpot.

Where a step's target is genuinely absent from the candidate list — an unlabelled
icon, a canvas control — the model may return `none`, and the step fails to the
recovery ladder rather than guessing.

## Consequences

**ADR 0003's contract holds without a patch.** Vision resolves a target, not a
point. Nothing in the system emits a coordinate, so the label denylist retains
both of its inputs and ADR 0001 is untouched.

> **Corrected 2026-09-20 — [ADR 0007](./0007-captured-targets-execute-by-synthesized-event.md).**
> True while ADR 0003 was in force, because the surfaces with no element tree were
> out of scope. ADR 0005 brought them in and this paragraph was not revisited.
> Vision still answers with an index and no model emits a coordinate; but where
> the selected target has no element to dispatch to, the executor computes a click
> point from the target's own bounds. The denylist keeps its inputs only because
> ADR 0007 adds the label this ADR's response format did not carry — the vision
> answer is now `{index, label}`, not `index` alone. Had we chosen a local grounding
model we would have had to hit-test its returned point back against the candidate
list — workable, but it reintroduces coordinates at exactly the boundary the
safety model was built to protect.

**Escalation requires network.** A task that escalates while offline fails. The
fast path — DOM, AX, OCR, Jev — still needs Jev, which is also network, so this
does not change the offline story: the application does not work offline at all.

**Escalation sends a window image to a third party.** This is the real cost of
the decision. The HUD must indicate when it happens, and a task operating on a
window with sensitive content will transmit it. A local model would have avoided
this; it was not fast enough to.

**Cost per escalation is ~$0.01**, against ~$0.000027 for a fast-path step —
roughly 370×. The escalation budget in `Constants.Budget.maxEscalations` is
therefore a real cost control, not a formality.

**Unlabelled icons remain the weak case**, but they are now merely slow rather
than impossible: the model can see an icon the OCR skeleton cannot, and the
numbered boxes give it something to answer with when the icon happens to fall
inside a detected region. An icon in a region nothing detected is still a miss.

This decision should be revisited if a GUI grounding model is converted to Core
ML and measured under ~500 ms on Apple silicon. Nothing else about the design
would need to change — the escalation interface already returns an index, and a
local model could be made to do the same.
