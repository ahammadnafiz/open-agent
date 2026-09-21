# ADR 0013 — The browser is borrowed, not kept

**Status:** Accepted, 2026-09-21.
**Completes** [0011](./0011-the-agent-drives-the-browser-you-actually-use.md),
which accounts for the browser at the start of a run and not at the end of one.

---

## Context

ADR 0011 decided the agent drives the user's own profile, and priced the
decision honestly at **one browser restart**. What it did not account for is the
state the browser is left in afterwards.

`--remote-debugging-port` is a startup flag, and Gecko treats the remote agent
as a property of the process, not of the connection. For the whole life of that
process:

- `navigator.webdriver` is `true`,
- the URL bar carries a robot icon and a "Browser is under remote control
  (reason: RemoteAgent)" notification,
- and bot detection reads the first of those.

Closing the BiDi client does not touch any of it. Nothing does, except the
process ending. So the flag outlived every run that wanted it, and the browser
the user went back to was the agent's browser wearing their tabs.

**Measured 2026-09-21.** A run ended at 13:16. At 14:11 the same process was
still up, and the user could not read `openai.com` on their own machine —
Cloudflare was serving them "Verify you are human", which is what
`navigator.webdriver` buys. Nothing in any log connected that wall to a run that
had finished an hour earlier, and the report that reached us was not "the agent
left a flag set". It was **"I can't browse."**

The first thing suggested was hiding the notification. That is the wrong repair
and worth recording as such: the banner and the wall are one cause wearing two
hats. Suppressing the banner would have left the user just as blocked and taken
away the only visible sign of why.

## Decision

**A run that ends for good hands the browser back:** it quits the browser
gracefully and reopens it with no debug port. The quit is the same one ADR 0011
already performs, so Gecko writes its session and the tabs come back; the
relaunch is `open -a`, the launch LaunchServices performs for a double-click,
because a browser being returned should be indistinguishable from one the user
started.

**Which endings count is decided by the status, not by the caller.**
`HostStatus.isTerminal` is exhaustive over the seven cases:

| Status | Browser |
|---|---|
| `completed`, `failed`, `blocked`, `unverified`, `budget_exhausted` | handed back |
| `needs_eyes`, `needs_plan` | kept |

`needs_eyes` and `needs_plan` are the two callbacks that exist so the host can
come back — SPEC.md § Boundaries. A browser restarted between one of them and
its resume discards the tab the run was working in and restores the rest
unloaded, which is the state that already made a following `observe` report a
site as not open at all. Handing the browser back there would break the feature
to fix the symptom.

Two escapes, because the agent cannot see either situation from inside one
invocation:

- `--keep-browser` holds it across a batch. A released browser has to be
  relaunched with the port to be drivable again, and that cold start is 5–7s
  (`Constants.Browser.launchTimeout`); a host with three tasks queued should pay
  it once, not twice in the middle. Because it is an opt-out from a fix for a
  defect the user experiences as "I can't browse", a run that exits still
  holding it **warns and names `release`** — set once and forgotten, an unheard
  flag reproduces the original defect exactly.
- `open-agent release` hands it back on demand. This covers the ending the agent
  genuinely cannot see: an `observe --browser` is deliberately *not* a
  hand-back, because the host almost always observes in order to then run, and
  only the host knows when it observed and then stopped.

`release` is idempotent and does nothing when nothing is listening, so a host
may call it blindly on its way out rather than tracking whether it needs to.

## What this does not solve

**`release` has no ownership test beyond "something is listening on the port."**
It takes no session and holds no lock, so a blind `release` issued while another
`--browser` invocation is mid-run will quit that run's browser out from under it.

This is not new to this decision — a profile takes one process at a time, so
concurrent browser invocations were already unsupported — and the fix is a lock
over the browser, not a guess inside `release`. It is recorded here because the
skill files now tell hosts to call `release` blindly, which is right for the
single-host case this product is built around and wrong the moment there are two.

## Consequences

- The cost ADR 0011 stated as "one browser restart" is now **two** — one to take
  the browser, one to give it back. That is the honest number, and it was always
  two; the second was simply never paid, and the user paid it by hand instead,
  if they worked out that they had to.
- On the dedicated profile this does nothing at all. The agent runs its own
  second copy there and the user's browser was never flagged, so there is
  nothing of theirs to return — and `tell application "Zen" to quit` is
  app-wide, not profile-scoped, so tidying up would close the window they are
  reading.
- A failed hand-back **never fails the task**. It runs after the work is done and
  reported; a browser that will not reopen is not a reason to call a finished
  send failed. But the `release` verb, whose whole job *is* the hand-back,
  reports `failed` with the sentence a human needs — three outcomes, not two.
  A `Bool` here told the host "nothing was under remote control" when the truth
  was "I tried and could not", and put the true account on stderr, which the
  contract forbids the host from reading.
- **Past the quit, the browser must be reopened.** A wait that times out is late,
  not fatal: the quit has been issued and the process will exit, so giving up
  there is how the user ends up with no browser at all — the exact failure the
  wait exists to prevent, arriving through the wait itself. The relaunch is
  verified afterwards too, because one issued while the old process is still
  quitting is silently swallowed.
- **A `--browser` run that dies before the loop also hands the browser back.**
  Those paths exit with `{"error":…}` rather than a status, so no host ever sees
  a reason to call `release` — and the browser they leave flagged is
  indistinguishable from the one a finished run leaves.
- The hand-back happens **after the session is saved and before the response is
  emitted.** The 5–7s restart must not sit between the loop ending and the
  durable write, or a process killed during it takes the run's state with it;
  and it must not sit after the response, because a host that reads the response
  may launch its next invocation immediately, and that one would attach to a
  browser this one is midway through quitting.

## Forbidden by this decision

- Suppressing the remote-control notification, by pref or by any other means.
  It is the user's only sign that their browser is not currently theirs, and the
  bot wall it accompanies does not read the notification.
- Handing the browser back on `needs_eyes` or `needs_plan`. See above: it
  discards the tab the resume is for.
- Restoring by relaunching the binary with the flags left off. `launch` and
  `restoreLaunch` are separate probes on purpose — one function with a boolean
  is one inverted boolean away from handing the user back a browser that is
  still under remote control.
