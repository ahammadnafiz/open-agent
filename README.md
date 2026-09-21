# open-agent

A macOS computer-use agent that carries out natural-language tasks against real
applications — invoked as a skill from the coding agent you already have open.

```
/open-agent reply to the latest message from my supervisor saying I'll get back to them tomorrow
```

A drawn cursor moves across your screen and does it. You watch. Anything that
cannot be undone stops and asks you first.

## Why it is built this way

Most computer-use agents send a screenshot to a vision model on every step. That
costs 2–4 seconds and several cents per step — expensive enough that most
harnesses skip verification and simply hope each action worked. When step 7
silently fails, steps 8–20 operate on the wrong screen and you find out at the
end.

This one verifies **every** step, because verification here costs **412 ms and
$0.000027** (measured). At that price the agent notices it is lost at step 7
rather than step 20.

Three parties, and none of them is allowed to do the others' job:

| | Does | Called |
|---|---|---|
| **Host agent** (Claude Code) | plans the route, looks at screenshots | ~3× per task |
| **Jev** (a System One model) | selects and verifies each individual step | every step |
| **Code** | all control flow, and every irreversible decision | always |

Handing the whole loop to a coding agent would reproduce exactly the problem
above. So the loop is not handed over.

## Safety

The irreversible boundary is **deterministic and upgrade-only**. `publish`,
`send`, `delete` and `purchase` are classified as irreversible in advance, not
judged per case, and no model result can waive it — five independent inputs feed
the gate and each can only ever *raise* it.

A model's risk scores are advisory. They decide whether to **ask**, never whether
to **allow**. Page text is attacker-controlled by construction, so no
attacker-influenced string is ever placed in a question whose answer relaxes a
restriction.

When an action cannot be undone, a window appears on your screen carrying the
exact payload and waits for you. The host agent is not asked, is not told, and
has no way to answer.

## Coverage is a gradient, not a boundary

It works anywhere. Accuracy and latency vary by how much the application will
tell you about itself.

| Tier | Source | Measured |
|---|---|---|
| 1 | DOM via WebDriver BiDi | 81% hit · 100% gate precision · 552 ms |
| 2 | Accessibility tree | 100% hit · 100% gate precision · 473 ms |
| 3 | Screen capture + Vision OCR | Electron, GPU-rendered, canvas |
| 4 | Vision model + numbered marks | 83% — 100% text, 71% icon · 4.8 s |

Each step takes the highest tier available for its target and falls through on
failure. A task is never refused for being on the wrong surface; it is answered
more slowly and less accurately as it descends.

**No model in this system ever emits a coordinate.** Vision sees candidates drawn
as numbered boxes and returns a *number*.

## Install

Requires macOS 26, Swift 6.2, and a TypeSafe API key.

```sh
git clone https://github.com/ahammadnafiz/open-agent
cd open-agent
./install.sh
```

That builds the release binaries onto `PATH` and installs the skill where the
host agent will find it. Two permissions are needed, and **both grants are
per-binary** — a freshly built executable is untrusted even in a granted
terminal:

- **Accessibility** — required
- **Screen Recording** — only for vision escalations

```sh
open-agent observe --app Finder      # what the agent can see right now
swift run Probe ax-tree Finder       # the same, with timings
```

## What it is not

- Not autonomous. It does not choose its own objectives or run unattended.
- Not a scripting tool. No macro recording, no replay of fixed selectors.
- Not a standalone app. It is a CLI driven by a coding agent.
- Not a host-agent loop. A design where the host drives every step is the design
  this one exists to beat.

## Design

245 tests, no dependencies. Every decision that was hard is written down with the
measurement that settled it.

| | |
|---|---|
| [SPEC.md](./SPEC.md) | what it does and why, end to end |
| [CONTEXT.md](./CONTEXT.md) | domain glossary |
| [docs/adr/](./docs/adr/) | architectural decisions, one per file |
| [docs/harness.md](./docs/harness.md) | the core loop — types, contracts, sequencing |
| [docs/jev-questions.md](./docs/jev-questions.md) | every Jev battery this project sends, verbatim |
| [docs/host-contract.md](./docs/host-contract.md) | the CLI and its two callbacks |

Status: working, and built for one person on one Mac. Read
[ADR 0009](./docs/adr/0009-the-agent-is-a-skill-and-the-host-model-plans.md)
first — it is the load-bearing decision.

## License

MIT — see [LICENSE](./LICENSE).
