# Context

Domain glossary for the macOS computer-use agent. Terms only — no implementation
detail, no decisions. Decisions live in `docs/adr/`.

## Task
A single natural-language instruction the user gives the agent, e.g. "open Zen,
go to my X handle, post about Jev". A Task is complete or failed; it is never
partially accepted. One Task expands into many Steps.

## Step
One iteration of the agent loop: observe the screen, decide one Action, execute
it, verify the result. A Step yields exactly one Action.

## Action
A typed operation the agent can perform. An Action is always semantic and always
names *what* it operates on, never *where* on screen. An Action that cannot name
its target is not a valid Action.

## Action Kind
The closed set of verbs an Action may use. The set is fixed, small, and known in
advance. Nothing outside the set can be executed.

## Reversible / Irreversible
A property of an Action Kind, decided in advance rather than judged per case.
**Irreversible** means the effect escapes the machine or destroys state that
cannot be recovered locally — publishing, sending, deleting, purchasing.
**Reversible** means the effect can be undone from this machine alone.
A published post deleted seconds later is still Irreversible: it was public.

## Element Reference
How an Action names its target: by the identity the system already gives that
element (accessibility path, DOM selector), never by pixel coordinate. Two runs
of the same Task on the same screen must produce the same Element Reference.

## Risk Gate
The judgment applied to Reversible Actions to decide whether to execute them
directly or ask the user first. The Risk Gate is advisory and probabilistic.
It never applies to Irreversible Actions.

## Confirmation
An explicit human approval of one specific Action, shown with the exact payload
that will be sent. Required for every Irreversible Action. A Confirmation
approves one Action, never a class of them and never a remainder of a Task.

## Fast Path
Handling a Step entirely from the text the system already exposes, without
capturing or interpreting an image of the screen.

## Escalation
Handling a single Step by falling back to interpreting an image of the screen,
because the Fast Path could not identify the target confidently. Escalation is
per-Step; it does not switch the whole Task.

## Plan
An ordered outline of intended Steps produced once, at the start of a Task, from
the instruction alone. A Plan is a hypothesis about the route, not a script. The
agent is expected to depart from it; departing is not failure.

## Verification
The judgment made after every Step about whether the Task moved forward. It is
distinct from whether the Action executed: an Action can execute perfectly and
leave the Task no further along, e.g. a navigation that lands on a login wall.
Verification asks about progress, never about mechanics.

## Blocked
A state in which the Task cannot proceed without something the agent does not
have and cannot obtain: a credential, a permission, a human decision. Blocked is
not failure and is never retried — retrying a login wall produces another login
wall. Blocked always surfaces to the user.

## Stuck
A state in which the agent is repeating itself without changing the screen.
Distinct from Blocked: nothing external is preventing progress, the agent has
simply stopped making any. Stuck is detected from recent history, not from a
single Step.

## Composition
Producing prose the Task requires — the body of a post, the text of a reply.
Distinct from every other model call in the system because its output is read by
a human rather than acted on by code, and because a refusal to compose is
visible and harmless where a refusal to plan would stall the agent.

## Candidate Set
The elements the agent considers as possible targets for one Step, after
deterministic filtering and before any judgment is applied. Membership is
decided by rules — rendered, on screen, labelled — never by a model.

## Element Source
Where the Candidate Set for a Step is read from. A target is either inside a
browser or it is not, and the two cases are read differently. The distinction is
not an implementation detail: the agent must know which world a Step operates in
before it can observe anything at all.
