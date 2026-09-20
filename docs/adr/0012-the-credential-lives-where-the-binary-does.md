# ADR 0012 — The credential lives where the binary does

**Status:** Accepted, 2026-09-20.
**Narrows** decision D1 in [`../open-agent-plan.md`](../open-agent-plan.md), which
made the process environment the only source of the API key.

---

## Context

D1 said no `.env` parser would live in this codebase, and gave a good reason:

> *"Every documented invocation of this project is `swift run` from a terminal,
> which inherits the shell environment for free."*

That premise expired when [ADR 0009](./0009-the-agent-is-a-skill-and-the-host-model-plans.md)
made the agent a skill and `install.sh` put `open-agent` in `~/.local/bin`. The
documented invocation is no longer `swift run` from the checkout. It is the host
coding agent running `open-agent run "…"` by name, from whatever directory the
user's *actual* task is in — a different repository, or their home directory.

`direnv` exports `.env` only inside this checkout. So the credential was scoped
to one directory and the command was not, and the measured result is this:

```
$ cd ~/Development/open-agent && direnv exec . sh -c 'echo ${TYPESAFE_API_KEY:+present}'
present
$ cd ~ && direnv exec . sh -c 'echo ${TYPESAFE_API_KEY:+present}'
                                                        # nothing
```

Every task that is not about this repository failed on step one, because Jev is
what resolves every click. The failure was also mis-diagnosed as "the key is not
set", which sent the next person to their shell profile — the one place that
would have worked, and the place a long-lived secret should least be, since
profiles get committed to dotfile repositories.

## Decision

**The key resolves from the environment first, then from
`~/.config/open-agent/credentials`.**

The environment wins because an explicit `export` is what a person reaches for
when they want to override what is installed, and a stored file that outranked
it would make that impossible. An empty environment value falls through to the
file, because `export TYPESAFE_API_KEY=` is how a shell unsets a variable it
already exported.

**This is not a `.env` parser, and the difference is why the file has its own
name and format.** `.env` is a format: `export ` prefixes, `#` inside quoted
values, CRLF, escapes — fifteen lines of the parts people get wrong, which is
exactly what D1 refused to own. This file holds one secret, read whole and
trimmed. There is nothing to get wrong because there is nothing to parse.

`install.sh` seeds the file from whatever key is already in the environment,
asking `direnv` for it rather than reading `.env` itself — reusing the parser
that already exists instead of writing a worse one in shell. It never
overwrites an existing file and never prints the value.

A file that is readable by anyone but its owner is tightened to `0600` on read
rather than refused. `ssh` refuses a loose private key and is right to, because
a leaked key must be replaced and the user has to know. This is not that:
refusing would abort the task at the moment it matters, and the only remedy
available to the user is the exact `chmod` we would have run.

## Consequences

- `open-agent` works from any directory, which is the only way the skill can
  work at all.
- The secret now exists in two files on the machine. Both are the user's, both
  are `0600`, and rotation means updating both — or dropping it from `.env`,
  since the file alone is sufficient for the installed command. `.env` remains
  the source for `swift run` inside the checkout.
- The failure message can now name both places it looked, so the next
  mis-diagnosis is harder.
- A Finder-launched `.app` still inherits neither source. Nothing bundles one
  today; when something does, Keychain is the third case and the shape is
  already `env → file → Keychain`.

## Forbidden by this decision

- Writing the key into a shell profile. It is a long-lived secret and profiles
  are shared, committed, and read aloud in screen shares.
- `UserDefaults`. It is a world-readable plist in `~/Library/Preferences`.
- Growing this file into a `.env` parser. If a second variable is ever needed,
  it gets its own file or the environment, not a format.
- Overwriting an existing credentials file during install. The one moment that
  would destroy work is immediately after the user set a new key by hand.
