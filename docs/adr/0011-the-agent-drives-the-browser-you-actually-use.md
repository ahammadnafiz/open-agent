# ADR 0011 — The agent drives the browser you actually use

**Status:** Accepted, 2026-09-20.
**Reverses** the profile half of [0002](./0002-fast-path-reads-dom-not-accessibility.md),
and the corresponding line in `SPEC.md` § Boundaries.

---

## Context

ADR 0002 and `SPEC.md` put this in the never-do set:

> *"Run the agent against a browser profile holding accounts the user did not
> explicitly assign to it."*

So the agent launched a dedicated, empty profile at
`~/Library/Application Support/open-agent/zen-profile`, and the documented
consequence was a one-time manual login per site:

> *"The agent profile starts logged into nothing, so the first task touching a
> new site returns `blocked ≈ 0.95` and stops. That is correct behaviour and it
> looks like a bug the first time."*

**In practice it does not look like a bug the first time. It looks like a bug
every time.** The observed result is a stack of empty browser windows next to
the browser the person is actually using, and every real task — *reply to this*,
*post that*, *find my order* — ends at a login wall the agent cannot pass.
A safety boundary that makes the product do nothing is not protecting anyone,
because nobody runs it.

## Decision

**The agent drives the default profile — the browser you actually use, with
every account you are logged into.** The dedicated profile remains available and
is no longer the default.

Two constraints are load-bearing and neither has a way around it:

1. **`--remote-debugging-port` is a startup flag.** Gecko exposes no runtime
   equivalent, so a browser that is already running cannot be told to start
   listening. This is why the agent could never simply attach.
2. **A profile takes one process at a time.** So using your profile means your
   running browser quits first.

The cost is therefore **one browser restart**, and the agent pays it by asking
the application to quit rather than signalling it, so Gecko saves session state
and the tabs come back. Measured on this machine: quit, relaunch and connect in
**2.2 s**, against **21.7 s** for a cold dedicated profile doing first-run setup.

The profile path is read from `profiles.ini` rather than hard-coded. Profile
directory names are randomised per install (`9ho70bff.Default (release)`), and
the per-install `[InstallXXXX] Default=` key is the one the browser honours —
on the machine this was built against it points somewhere different from the
`Default=1` flag under `[Profile1]`, so reading the wrong key opens the wrong
profile.

## What this costs, stated plainly

**The agent can reach every account that browser is signed into.** Page content
is attacker-influenced by construction, it reaches a model's `state`, and a
measured semantic reframing moved a Jev risk score from 0.98 to 0.42. The
mitigation is not the profile boundary any more; it is the one that was always
doing the real work:

- `Irreversibility.classify` is deterministic and upgrade-only. No model verdict
  waives it — ADR 0001.
- `publish`, `send`, `delete` and `purchase` show a window with the exact
  payload and wait for a human. There is no flag that answers it.
- The risk battery decides whether to **ask**, never whether to **allow**.

That set was always the boundary that mattered. The empty profile was a second
fence around a field nobody could enter.

## Consequences

- `Probe browser-login` is no longer part of normal setup. It remains for the
  dedicated-profile mode.
- Quitting the user's browser is an action the agent takes on their machine, so
  it is a caller decision (`allowRestart:`) and never a silent default inside
  the launcher.
- `SPEC.md` § Boundaries must be corrected. Leaving a rule in the never-do set
  that the code deliberately breaks is worse than having no rule: the next
  person to read it cannot tell which of the other entries are still true.

## Forbidden by this decision

- Quitting a browser without asking the application to quit first. A `SIGKILL`
  loses the session and leaves the profile lock behind.
- Launching a second browser when one is already listening. That is what stacked
  up empty windows, and it is now a check rather than a retry.
- Treating the profile as a safety boundary. It is a convenience decision now.
  The gate is the boundary.
