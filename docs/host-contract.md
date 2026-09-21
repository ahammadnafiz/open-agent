# The Host Contract

How `open-agent` and the coding agent driving it talk to each other. The CLI is
the contract; the skill files are thin wrappers over it, one per host. When a
skill file and this document disagree, this document is right.

Decided in [ADR 0009](./adr/0009-the-agent-is-a-skill-and-the-host-model-plans.md).

---

## 1. The division of labour

Restated, because every model call in this system should be justifiable by it.

| Job | Who | Why not someone else |
|---|---|---|
| Decide the route | **host** | Jev is not an agent and does not choose its next action — their docs say so |
| Re-decide it when the screen is not what the plan assumed | **host** | Same, and it is now interactive, which a single API call never was |
| Pick an element | Jev | 412 ms and $0.000027; a host round trip is seconds and a tool call for the same answer |
| Check it worked | Jev | Cheap enough to do on *every* step, which is the entire thesis |
| Triage risk | Jev | Advisory only; the real boundary is deterministic |
| See pixels | **host** | Jev is text-only. Set-of-Marks, index back — ADR 0004 |
| Write prose | **host** | Jev cannot generate text at all |
| Decide irreversibility | **code** | Non-deterministic, injectable, unrecoverable if wrong |
| Approve an irreversible action | **a human, in a window** | See §5 |
| Count, compare dates, arithmetic | **code** | Documented `jev-1.13` failure modes; code is exact |

**The host is called roughly three times per task, not twenty.** If that number
climbs, shape B is degrading into shape A and the latency thesis is going with
it. `Budget.maxEscalations` is the ceiling that keeps it honest.

---

## 2. The verbs

```bash
open-agent run "<task>" --plan plan.json [--url <site>]
open-agent resume <session> --eyes <n> | --eyes none
open-agent resume <session> --plan plan.json
open-agent observe [--app <name> | --browser [--url <site>]]
open-agent act --session <s> --kind <kind> --target <id>
open-agent overlay [--loop] [--speed <n>] [--at x,y …]
```

Each invocation prints **one JSON object** to stdout and exits. Exit code 0
means a status the host can act on; non-zero means the invocation itself was
malformed. The host never parses prose, and nothing but JSON goes to stdout —
logs go to stderr.

**`observe --browser` takes `--url`, and a host that omits it is guessing.**
The browser exposes no notion of "the tab the person is looking at", and BiDi
context ids do not survive the process that learned them — so without a site to
match on, the tab falls back to the first loaded one in a named container.
Measured: a run navigated to a repository's issues, and the `observe` after it
reported twenty-one candidates from an unrelated tab in the same browser, with
`completed` and no hint that it had answered about somewhere else. The `reason`
now names the address that was actually read, so a mismatch is visible in the
response rather than inferred from the labels.

**A browser plan whose steps include no `navigate` must pass `--url`.** The
tab a run works in is settled from the plan's first navigation, because that
step names the site. With no navigation the site is unnamed, and the tab fell
back to whichever one `resolveContext()` guessed at connect time — measured, a
scroll-only plan meant for a Facebook feed scrolled a blank tab nine times and
scored `progressed 0.15`, with nothing wrong in any log. `--url` names it.

It matches, it never opens: a tab nothing is going to load is not the site that
was asked for, and `no tab is open on <site>` is the honest answer. A plan
*with* a `navigate` step still opens one, since that step is about to fill it.
The same rule governs `observe --browser --url`.

**A `scroll` step names no on-screen element**, like `openApp`, `navigate` and
`wait`. A wheel needs a point, and the container a plan wants to scroll — a
feed, a message list, a page — is never a candidate, because the snapshot
collects only what can be acted on. Selection against that name matched
whatever was nearest instead: measured on a Facebook feed, nine `scroll the
news feed` steps resolved to `Leave a comment`, `Leave a comment`, `View more
comments`, each anchoring the wheel on a comment box and each costing a Jev
call. The step's `target` is now prose for the log, the wheel goes to the
middle of the viewport, and no selection call is spent.

`run` and `resume` carry session state on disk between invocations rather than
holding a process open. A coding agent's tool calls are separate processes with
gaps between them, so a long-lived daemon would be one more thing to supervise
for no gain.

---

## 3. The status field

The only field the host branches on.

| `status` | Raised when | Host does |
|---|---|---|
| `needs_eyes` | `sufficient < 0.70`, or confidence/margin below the gate | read the screenshot, `resume --eyes <n>` |
| `needs_plan` | recovery ladder rung 2, or `progressed` low ∧ `unchanged` low | read `history` + `candidates`, `resume --plan` |
| `blocked` | `blocked ≥ 0.70` | **stop.** Tell the user what is in the way. Never retry |
| `completed` | `task_done ≥ 0.80` | report |
| `failed` | ladder exhausted | report with the step log |
| `budget_exhausted` | a ceiling in `Constants.Budget` was hit | report what was done |

```jsonc
{
  "session": "s_01J…",
  "status": "needs_eyes",
  "step": 7,
  "elapsed_ms": 4180,
  "cost_usd": 0.00019,
  "screenshot": "/…/s_01J…/step-07.png",
  "candidates": { "1": "New mail", "2": "Archive", "…": "…" },
  "history": ["click New mail", "click To", "type ahammad…"],
  "text": "Inbox 3 unread …",
  "reason": "sufficient 0.41 — the target is not in the element list"
}
```

**`candidates` says what can be pressed; `text` says what it says.** They are
different questions and only the first was ever answered. A candidate list of
a page of issues carries the issue *titles*, because a title is a link and a
link contributes its own text — and carries nothing at all about their state,
their labels, or their bodies. The browser tier walks the page's text nodes on
every snapshot and had always thrown the result away, so a host asking "what
does this page say" had to open the page itself.

The field is present when the tier driving the run can read prose, and absent
otherwise — the accessibility tier walks a tree of controls, not a document,
and leaves it out rather than inventing one. It is capped at 6000 characters
(`TEXT_LIMIT` in `SnapshotScript`).

### 3.1 `needs_eyes`

The screenshot has the candidate boxes drawn on it as numbered marks. The host
replies with **the number**, or `none` if the target is genuinely absent.

This is Set-of-Marks exactly as [ADR 0004](./adr/0004-vision-is-cloud-and-returns-an-index.md)
decided it. Only the model answering has changed. Two things that did not:

- **The answer is an index, never a coordinate.** Asking for a point measures
  worse — ScreenSpot-Pro puts coordinate regression at 17.1 where marks took
  GPT-4V from 16.2 to 73.0.
- **The answer carries a short label** — "the paper-aeroplane send icon". Not
  decoration: 74.2% of pressable elements are icon-only, the tier 3b detector
  returns boxes with no labels, and without that string `LabelDenylist` has
  nothing to match on exactly those targets. See
  [ADR 0007](./adr/0007-captured-targets-execute-by-synthesized-event.md) §3.

```jsonc
// resume --eyes, as the host supplies it
{ "index": 7, "label": "the paper-aeroplane send icon" }
```

**Scope is the focused window, not the display.** A full-screen capture includes
the agent's own overlay and every other application — irrelevant context that
costs accuracy and tokens.

**Privacy, stated plainly:** an escalation puts an image of the window into the
host's context, and from there wherever that host sends it. The overlay indicates
when this happens. A task operating on a window with sensitive content will
transmit it. This was true with OpenRouter and is equally true now; the vendor
changed, the exposure did not.

### 3.2 `needs_plan`

The route was wrong. The host gets the current element list, the recent history
and why the previous plan step failed, and returns replacement steps.

```jsonc
{ "steps": [ { "kind": "click", "target": "the account switcher", "payload": null } ] }
```

Plan steps name targets **semantically** — "the compose button" — never as
coordinates and never as element ids. The binary re-resolves the actual element
from the live screen through Jev, which is the whole reason a stale plan is
survivable.

`declaredIrreversible` is set only for steps that publish, send, delete or
purchase. It is one of five inputs to `classify` and it can only ever raise the
result, so a host that declares too much costs an extra confirmation and a host
that declares too little is caught by the other four.

---

## 4. What the skill file must say

The skill is markdown. It is allowed to be short, and it must contain these
four things:

1. **Parse `status`, branch on it.** Never infer state from prose.
2. **`blocked` is terminal.** Do not retry, do not work around it, do not try
   another route. Tell the user what is in the way and stop. Retrying a login
   wall produces another login wall.
3. **Ask the user when the task names something only they know.** "My company
   email", "the usual reviewer", "that repo" — ask rather than guess. This is the
   capability a non-interactive planner never had; not using it wastes the pivot.
4. **Never claim an action happened because a call returned.** The executor
   reports *mechanics*. Only the next step's Jev batch reports progress.

And one thing it must **not** contain: any instruction about approving actions.
See §5.

---

## 5. Approval is not part of this contract

An irreversible action shows a **native macOS sheet carrying the exact payload**
and blocks until a human clicks it. Shown for irreversible actions only, never
per turn.

The host is not asked, is not told, and cannot answer. The call simply takes
longer, and human time is never charged against the task budget.

**There is no flag that approves an action.** Not `--yes`, not `--force`, not
`--approved`, not an environment variable, not a config key. This is not caution
about the host: page text reaches the host's context by construction, and a
measured semantic reframing moved a Jev risk score from 0.98 to 0.42. Anything
expressible as an argument is eventually expressible by an injected instruction.
A window is not.

`SafetyTests` asserts this the way it asserts the rest of ADR 0001 — by
enumeration, not by reading the code.

---

## 6. Jev is unchanged, and still ours

The host replaced the two OpenRouter roles. It did not replace Jev, and the
distinction is the project.

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
- `x-typesafe-request-id` goes in the step log. It is the only handle for support.
- There is **no Swift SDK** — Python and JS only. This client is hand-written
  against the HTTP API, which is small enough that this is not a burden.

A session spans several `run`/`resume` invocations, so the warm connection dies
between them. The 383 ms figure applies within one invocation; the first Jev call
after a resume pays the cold ~900 ms. Budget for it, and do not mistake it for a
regression.
