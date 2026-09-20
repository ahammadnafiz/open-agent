# Model Contracts

Three model backends, each doing one job it is uniquely suited to. They are
deliberately **not** abstracted behind a common interface — they are not
interchangeable, so there is nothing to swap.

| Role | Backend | Frequency | Latency | Cost |
|---|---|---|---|---|
| Plan | OpenRouter `anthropic/claude-sonnet-5` | once per task | ~2–3 s | ~$0.005 |
| Select + verify + triage | Jev `jev-1.13.0` | every step | **468–552 ms** ᴹ | $0.000027 |
| Compose prose | Apple Foundation Models | when text is needed | ~1.3 s ᴹ | free |
| See | OpenRouter **`google/gemini-3.8-flash`** | on escalation only | **4.8 s** ᴹ | **$0.00096** ᴹ |

ᴹ = measured on this machine. Jev latency is the full step battery end to end on
real pages, including ~250 ms network round trip from this location.

---

## 1. OpenRouter

`POST https://openrouter.ai/api/v1/chat/completions`, OpenAI-compatible.
`Authorization: Bearer $OPENROUTER_API_KEY`.

### 1.1 Model selection

Verified against the live OpenRouter catalogue. All are vision-capable:

| Model ID | $/M input | Use |
|---|---|---|
| `anthropic/claude-sonnet-5` | $2.00 | **planner** — once per task |
| **`google/gemini-3.8-flash`** | **$0.75** | **vision escalation** — see ADR 0004 |
| `google/gemini-3.5-flash-lite` | $0.30 | cheaper, but 57% vs 71% on icon targets |
| `anthropic/claude-opus-5` | $5.00 | fall back *up* for a hard replan |

Note `google/gemini-3-pro` is **not on OpenRouter** — the 72.7 ScreenSpot-Pro
figure widely cited for it belongs to a model you cannot call here. The available
flagship line is `gemini-3.8-flash` / `3.5-flash` / `2.5-pro`.

Model IDs are configuration, not constants in code. OpenRouter's catalogue moves;
`Constants.Models` holds the defaults and they are overridable without a rebuild.

Send OpenRouter's attribution headers so usage is traceable in the dashboard:

```
HTTP-Referer: https://github.com/<you>/computer-agent
X-Title: Computer Agent
```

### 1.2 Planner

Runs once per task. Returns a `Plan` — a hypothesis about the route, not a
script. The loop is expected to depart from it.

```swift
let system = """
You plan macOS computer-use tasks as an ordered list of concrete UI steps.

Use only these kinds:
  openApp, navigate, click, type, scroll, focus, select, read, wait,
  publish, send, delete, purchase

Rules:
- Name targets semantically ("the compose button"), never as coordinates.
- Set declaredIrreversible true ONLY for steps that publish, send, delete,
  or purchase.
- Do not plan verification steps. The harness verifies every step itself.
- Prefer fewer, larger steps. The harness re-decides the actual target from
  the live screen, so a step that says "open the composer" is better than
  three steps guessing at a click path.
- At most 10 steps.
"""
```

Request JSON Schema via `response_format` so the output is parseable without
repair. Structured output does not hurt classification-shaped tasks — the
documented degradation is on reasoning benchmarks, not on this.

**Failure handling.** A malformed plan is not recoverable by retry-with-the-same-
prompt; it means the task description was unusable. Surface it to the user rather
than burning budget. An empty plan is the same case.

### 1.3 Vision fallback — Set-of-Marks

Called only when the fast path cannot resolve a target: `sufficient` below
threshold, selection confidence or margin too thin, or the recovery ladder
reached rung 1.

**The model is never asked where to click. It is asked which numbered box.**

```swift
struct VisionRequest {
    let screenshot: Data          // PNG, focused window only, candidate boxes
                                  // drawn on it and numbered 1…n
    let task: String
    let planStep: PlanStep
    let candidates: [Element]     // the same list the fast path saw, numbered
    let history: [String]
}

enum VisionAnswer {
    case element(Int)             // index into candidates
    case none                     // target genuinely not present → recovery ladder
}
```

Render the candidate bounding boxes onto the screenshot with their numbers, and
send the numbered list as text alongside. The model replies with a number.

This is [Set-of-Marks](./adr/0004-vision-is-cloud-and-returns-an-index.md), and
it is doing two jobs at once:

- **It preserves the contract.** Vision resolves a *target*, not a point. Nothing
  in the system emits a coordinate, so the label denylist keeps both of its
  inputs and ADR 0001 is untouched.
- **It is more accurate than asking for a coordinate.** Pairing a detector with
  numbered marks moved GPT-4V from **16.2% → 73.0%** on ScreenSpot. Turning a
  grounding problem back into a selection problem is the single highest-leverage
  thing you can do to a vision step.

A local grounding model would have forced the opposite shape — every open model
in this class emits a point, which would have needed hit-testing back against the
candidate list. Cloud vision avoids that entirely. See ADR 0004 for why local was
rejected on measured latency (11–17 s on M4 Pro).

**Screenshot scope is the focused window, not the display.** A full-screen capture
includes the agent's own HUD and every other application — irrelevant context that
costs accuracy and tokens.

**Privacy, stated plainly:** escalation sends an image of the window to a third
party. The HUD must indicate when this happens. A task operating on a window with
sensitive content will transmit it.

Screenshot scope is the focused window, not the display. A full-screen capture
includes the agent's own HUD, other applications, and whatever else is on screen,
all of which is irrelevant context that costs accuracy and tokens.

**Privacy note worth being explicit about:** escalation sends an image of the
window to a third party. The HUD indicates when this happens. A task on a window
containing sensitive content will transmit it.

### 1.4 Retry and cost

```swift
// 429 and 5xx: exponential backoff, 3 attempts, honour Retry-After.
// 400: do not retry — it is a malformed request, and retrying burns budget
//      to receive the identical error.
```

Every response's `usage` is charged to the task `Budget`. OpenRouter returns
token counts; multiply by the model's rate from the catalogue rather than
hardcoding, because prices change.

---

## 2. Jev

Full battery specification: [jev-questions.md](./jev-questions.md).

```swift
actor JevClient {
    // ONE warm connection for the process lifetime.
    // Measured: 383 ms warm vs ~900 ms cold. TLS + TCP to their edge costs
    // ~520 ms from this location; reconnecting per step more than doubles
    // step latency.
    private let session: URLSession

    func step(_ ctx: StepContext) async throws -> StepVerdict
}
```

- Model **pinned** to `jev-1.13.0`. Never `jev-latest`.
- Record `response.model` on every `Step` — an alias moving is a silent
  behavioural change and this is the only way to notice.
- Retry 429/529 with backoff; the SDKs do this and a hand-rolled client must too.
- `x-typesafe-request-id` goes in the step log. It is the only handle for
  support.
- There is **no Swift SDK** — Python and JS only. This client is hand-written
  against the HTTP API, which is small enough that this is not a burden.

---

## 3. Apple Foundation Models

On-device, free, no key, no network. Used for **prose composition only**.

```swift
import FoundationModels

guard case .available = SystemLanguageModel.default.availability else {
    return try await openRouter.compose(prompt)   // see Open Question Q4
}
let session = LanguageModelSession(instructions: "Write concise social posts. Under 200 characters.")
let text = try await session.respond(to: prompt).content
```

### 3.1 Measured behaviour and hard limits

```
plain text generation           1.33 s   OK, good quality
array-of-structs schema         0.65 s   OK — with SHORT instructions
flat struct schema              FAIL     guardrailViolation
plain gen + 10KB context        2.07 s   OK but HALLUCINATED detail not in input
long instructions + schema      FAIL     4,090 of 4,096 tokens — overflow
```

Three limits, all load-bearing:

1. **4,096 token context, total.** A verbose instruction string plus a nested
   `@Generable` schema overflows it before any input arrives. This is why the
   on-device model does not plan.
2. **`guardrailViolation` fires unpredictably** — observed on a completely benign
   UI-automation prompt. The filter is opaque and non-configurable.
3. **Quality degrades with context.** At 10KB it invented a detail ("top-left
   corner") that appeared nowhere in the input.

### 3.2 Why composition, and only composition

The guardrail risk has to live somewhere. Put it where failure is **visible and
harmless**: a refused composition leaves an empty text box, the user sees it
immediately, and the step retries. A refused *plan* would stall the agent before
it started, for reasons the user cannot see or fix.

Nothing safety-critical and nothing control-flow-critical may depend on an opaque
filter. That is the whole placement argument.

### 3.3 Fallback

On `guardrailViolation` or overflow, route composition to OpenRouter. Whether
that is silent or surfaced is **Open Question Q4** — silent fallback quietly
contradicts "runs on-device" as a product claim, and the honest default is to
show it in the HUD.

---

## 4. The division of labour

Restated, because every model call in this system should be justifiable by it:

| Job | Who | Why not someone else |
|---|---|---|
| Decide the route | Claude | Jev is not an agent and does not choose its next action — their docs say so |
| Pick an element | Jev | 412 ms and $0.000027; a VLM is 2–4 s and ~$0.01 for the same answer |
| Check it worked | Jev | Cheap enough to do on *every* step, which is the entire thesis |
| Triage risk | Jev | Advisory only; the real boundary is deterministic |
| Write prose | Apple FM | Jev cannot generate text at all; Claude would be a network round trip for a tweet |
| See pixels | Claude | Jev is text-only; Apple FM has no vision |
| Decide irreversibility | **code** | Non-deterministic, injectable, and this is unrecoverable if wrong |
| Count, compare dates, arithmetic | **code** | Documented `jev-1.13` failure modes; code is exact |
