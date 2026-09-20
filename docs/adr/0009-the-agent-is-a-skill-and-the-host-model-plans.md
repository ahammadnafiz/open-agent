# 9. The agent is a skill, and the host coding agent does the planning and the seeing

Date: 2026-09-20

## Status

Accepted. Supersedes the model roles in
[ADR 0004](./0004-vision-is-cloud-and-returns-an-index.md) — the Set-of-Marks
*technique* it decided survives unchanged; only the vendor behind it moves.
Renames the project to **open-agent**.

## Context

The original design called three model vendors: OpenRouter for planning
(`claude-sonnet-5`) and vision escalation (`gemini-3.8-flash`), TypeSafe for Jev,
and Apple Foundation Models on-device for prose. Two API keys, two billing
relationships, and a planner that could only ever be a single non-interactive
call.

Meanwhile the person running this already has a coding agent open — Claude Code,
Codex — which plans, sees images, writes prose, asks clarifying questions, and
runs an agent loop. Every OpenRouter role in the design is a capability sitting
idle one terminal away.

The obvious move is to let the coding agent do those jobs and ship this as a
skill it invokes. The non-obvious part is **how much** to give it, and getting
that wrong destroys the project.

**The thing that must not be given away.** SPEC.md opens by attacking this:

> Existing computer-use agents send a screenshot to a vision model on every step.
> That costs 2–4 seconds and several cents per step, which is expensive enough
> that most harnesses skip verification and simply hope.

If the host agent does per-step *selection and verification*, every step becomes
a full LLM turn and this becomes the thing it was built to beat. A ten-step task
would be twenty tool calls and twenty turns. The 412 ms / $0.000027 measurement
is not a detail of the design; it is the design.

So the split is not "the coding agent does everything." It is: **the host agent
decides the route and looks at pictures; Jev runs every step in between.**

Two loop shapes were weighed.

**A. The host agent in the loop.** `observe` → think → `act`, two tool calls per
step. Trivial to build. 2–5 s per step, cents per step, no fast path, thesis gone.

**B. The binary owns the loop and calls out only when it is stuck.** The host
plans once, invokes `open-agent run`, and Jev drives every step at ~500 ms. When
the element list is not enough, or the route turns out to be wrong, the binary
returns a structured request and the host answers it. Roughly three tool calls
for a whole task rather than twenty.

## Decision

**B.** `open-agent` is a CLI. A skill file — `/open-agent` in Claude Code, the
equivalent in Codex — is a thin wrapper telling the host how to drive it. The
skill is per host; the CLI is the contract, and it is what is actually being
built.

### Who does what

| Job | Who | Changed? |
|---|---|---|
| Decide the route, and re-decide it | **host coding agent** | was `claude-sonnet-5` via OpenRouter |
| Look at the screen when text is not enough | **host coding agent** | was `gemini-3.8-flash` via OpenRouter |
| Write prose for a human to read | **host coding agent** | was Apple Foundation Models |
| Select an element, every step | Jev `jev-1.13.0` | unchanged |
| Verify progress, every step | Jev `jev-1.13.0` | unchanged |
| Triage risk, advisory | Jev `jev-1.13.0` | unchanged |
| Perceive, execute, draw the cursor | **this binary** | unchanged |
| Decide irreversibility, gate it | **this binary, deterministically** | unchanged |

### The two callbacks

`open-agent run` returns structured JSON and exits whenever it cannot proceed
alone. The host answers and calls `resume`.

| Status | Raised when | Host receives | Host returns |
|---|---|---|---|
| `needs_eyes` | `sufficient < 0.70`, or confidence/margin below gate | marked-up screenshot path + numbered candidate list | one index, or `none` |
| `needs_plan` | recovery ladder rung 2 | current element list, history, what failed | replacement plan steps |
| `blocked` | `blocked ≥ 0.70` | the obstacle | nothing — surfaced to the user, never retried |
| `completed` / `failed` / `budget_exhausted` | terminal | the step log | nothing |

`needs_eyes` is Set-of-Marks exactly as ADR 0004 decided it — numbered boxes, an
index back, never a coordinate. Only the model answering has changed, and the
answer still carries the label ADR 0007 requires.

### Approval is a window this binary owns

An irreversible action shows a **native macOS sheet with the exact payload** and
blocks until a human clicks approve. It is shown for irreversible actions only,
never per turn.

The host agent is not consulted and cannot answer. There is no CLI flag that
approves an action — no `--yes`, no `--force`, no `--approved`. That is not
caution about the host; it is that page content reaches the host's context, and
a measured semantic reframing moved a Jev risk score from 0.98 to 0.42. Anything
expressible as an argument is eventually expressible by an injected instruction.
A window is not.

## Consequences

**The thesis survives intact.** 84% of steps stay on the Jev fast path at ~500 ms
and $0.000027. The host is called roughly three times per task rather than twenty.

**Three files are never written:** `OpenRouterClient.swift`, `Planner.swift`,
`VisionFallback.swift`. `OnDeviceWriter.swift` goes with them.

**Open Question Q4 closes.** Apple FM's unpredictable `guardrailViolation` on
benign prompts was the reason Q4 existed. Composition now happens in the host.
The on-device privacy claim goes too — it was already undermined by shipping
window images to a third party on every escalation.

**The planner became interactive, and that is a real gain nobody planned for.**
A single non-interactive OpenRouter call had to guess what *"my company email"*
meant. A host agent asks. Tasks that name things only the user knows — an
employer's mail provider, which of two accounts, what "the usual" means — stop
being failure modes and become one question in a terminal.

**The recovery ladder gets a branch it did not have.** Rung 0 is retry, and retry
is correct only when the action did nothing. Jev distinguishes the two cases and
the ladder ignored it:

- `progressed` low ∧ `unchanged` **high** → the click missed → **retry**
- `progressed` low ∧ `unchanged` **low** → the screen moved, just not toward the
  goal → retrying is pointless → **skip to `needs_plan`**

The second case is what "the screen is new" looks like from inside the loop. The
fixtures separate cleanly (0.84/0.91 on genuine no-ops against 0.02–0.06
otherwise), so this branch is cheap and well supported.

**The battery has a gap this pivot did not create but did expose.** On a task
naming a specific account, mailbox or document, the agent can land on a
*plausible but wrong instance* — the personal inbox instead of the company one —
and every one of the five verification questions answers correctly while the task
proceeds to the wrong place. `wrong_context` is added to the battery to cover it;
see [jev-questions.md](../jev-questions.md) §2.2. It is unmeasured.

**Host constraints are now inherited and are not controllable.** Context
compaction mid-task, rate limits, and a tool-call round trip on every callback.
Budget: three callbacks is comfortable, and if escalations become common shape B
degrades toward shape A without announcing itself. `Budget.maxEscalations = 3`
was already the ceiling; it is now also the thing keeping the architecture honest.

**This stops being a Mac application and becomes a developer tool.** The audience
narrows to people already running a coding agent. For v1 that is the right trade —
it is the shortest path to something that works — but it is a positioning
decision and not only a technical one.

**The overlay matters more, not less.** With the interface in a terminal, a drawn
cursor over the real screen is the only way to watch what is happening.
