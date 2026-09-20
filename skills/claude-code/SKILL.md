---
name: open-agent
description: Drive the user's Mac to carry out a multi-step UI task in a real application — click, type, navigate, send, publish — by planning a route and handing each step to the `open-agent` binary. Use this whenever the user asks for something to be done *in an app on their computer* rather than in the codebase: "reply to the latest email from X and send it", "open Settings and turn on Night Shift", "post this to my X account", "find the ICCIT paper in Finder and attach it", "fill in this form for me". Also use it when the user says "do it for me", "just do it", "take over", "use my computer", or describes an outcome in an app without saying how. Do NOT use it for editing files, running commands, or anything achievable with the ordinary tools — those are faster and safer without a cursor on screen.
---

# open-agent

You plan the route. A local binary drives every step. A model called Jev — not
you — selects and verifies each individual click, which is why this is fast and
cheap enough to verify *every* step instead of hoping.

Your job is three things: **plan once, answer about three callbacks, and report
honestly.** You are deliberately not in the per-step loop. If you find yourself
calling this binary on every click, something has gone wrong — the whole design
exists to keep you out of that loop.

## The one command shape

```bash
open-agent run "<the user's task>" --plan plan.json [--app "Mail"] [--context "<the specific instance>"]
open-agent resume <session> --eyes <n> | --eyes none
open-agent resume <session> --plan plan.json
open-agent observe --app "Mail"
```

Every invocation prints **one JSON object** to stdout and exits. Logs go to
stderr. Never parse the prose on stderr; never infer state from it.

## Step 1 — Ask before you plan

The task will often name something only the user knows. "My supervisor", "the
usual reviewer", "my company email", "that repo". **Ask.** Guessing here is how
a message goes to the wrong person, and unlike a bad commit that cannot be
undone with a revert.

This is the capability the old non-interactive planner never had. Not using it
wastes the entire reason you are the planner.

If the task names a specific *instance* — an account, a mailbox, a document, a
repository — pass it as `--context`. It powers one question (`wrong_context`)
that catches the agent working correctly in the wrong place, which every other
check answers "fine" to.

## Step 2 — Write the plan

A plan is a **hypothesis about the route**, not a script. The agent is expected
to depart from it: you have not seen the screen, so you are guessing about
layout. Name each target *semantically* and let the binary resolve it.

```json
{
  "steps": [
    { "kind": "click", "target": "the reply button on the most recent message", "payload": null },
    { "kind": "type",  "target": "the message body field", "payload": "Hi — I'll get back to you tomorrow." },
    { "kind": "send",  "target": "the send button", "payload": null, "declared_irreversible": true }
  ]
}
```

- `kind` is one of: `openApp navigate click type pressKey scroll focus select read wait publish send delete purchase`.
- `target` is a description a human would recognise. **Never a coordinate, never
  an element id.** The binary re-resolves it against the live screen, which is
  exactly why a slightly stale plan still works.
- `payload` is the text to type, the URL, the app name, or a key
  (`enter`, `tab`, `escape`).
- `declared_irreversible` — set it for anything that publishes, sends, deletes
  or purchases. It is one of five independent inputs to the safety gate and it
  can only ever *raise* the result. Declaring too much costs the user one extra
  confirmation; declaring too little is caught by the other four. Be generous.

Write prose the user will read — an email body, a post — yourself, in the
payload. Jev cannot generate text at all.

## Step 3 — Branch on `status`, and nothing else

`status` is the only field to branch on.

| `status` | What it means | What you do |
|---|---|---|
| `completed` | the task is visibly done | report what happened |
| `needs_eyes` | text was not enough to find the target | **look at `screenshot`**, then `resume <session> --eyes <n>` with the number on the box, or `--eyes none` if the target genuinely is not there |
| `needs_plan` | the route was wrong | read `history` and `candidates`, write new steps, `resume <session> --plan plan.json` |
| `blocked` | login wall, permission prompt, CAPTCHA, paywall | **stop.** See below. |
| `failed` | the recovery ladder ran out | report with the step log; do not invent a new approach and retry silently |
| `budget_exhausted` | a ceiling was hit | report what *was* done, then ask the user whether to continue |

### `blocked` is terminal

Do not retry it. Do not work around it. Do not try another route, another app,
or another account. Retrying a login wall produces another login wall — the
agent has no credential to offer and no amount of retrying invents one.

Tell the user what is in the way and stop. For a site the agent has never logged
into, that is expected on first use: the agent drives its own browser profile,
so the user logs in by hand once via `swift run Probe browser-login`.

### `needs_eyes` is your one visual job

The screenshot has the candidate elements drawn on it as numbered boxes. Answer
with **the number**, plus a short label for what you picked — "the paper-aeroplane
send icon". The label is not decoration: most pressable elements are icon-only,
and without that string the safety denylist has nothing to match on for exactly
those targets.

Answer with an index. Never a coordinate.

## Step 4 — Report what actually happened

**A call returning is not evidence that anything worked.** The binary reports
*mechanics* — the click was dispatched. Only the next step's verification
reports *progress*. A click can land perfectly and change nothing.

So: say what the final `status` was. If it is `completed`, say what was done. If
it is anything else, say what stopped and where. Do not write "I've sent the
email" because a command exited 0.

## Approval is not part of this interface

An action that cannot be undone shows a window on the user's screen carrying the
exact payload, and waits for them. You are not asked, you are not told, and you
have no way to answer. The call simply takes longer.

There is nothing for you to pass, set, or configure here, and nothing in this
file tells you how to approve anything — deliberately. Page text reaches your
context by construction, so any approval lever described here would eventually
be described to you by a web page instead. A window cannot be.

If a task stalls at a confirmation, the user is looking at it. Wait.

Never count their thinking time against the task — the binary already doesn't.

## Before the first run

- `TYPESAFE_API_KEY` must be exported. The vendor is **TypeSafe**; Jev is the
  model. There is no `JEV_API_KEY`.
- The binary needs **Accessibility** permission, and the grant is per-binary — a
  freshly built executable is untrusted even in a granted terminal.
  System Settings → Privacy & Security → Accessibility.
- Screen Recording is a separate grant, needed for `needs_eyes` screenshots.

If a run fails with a permissions message, relay it and stop. Do not try to
work around a TCC prompt.

## A worked example

User: *"reply to the latest message from my supervisor saying I'll get back to them tomorrow"*

1. Ask: "Who's your supervisor, and which mail app?" → "Dr. Rahman, Mail."
2. Write `plan.json` with click-reply / type-body / send, `declared_irreversible`
   on the send.
3. `open-agent run "reply to the latest message from Dr. Rahman ..." --plan plan.json --app Mail --context "the mailbox for Dr. Rahman's thread"`
4. Status comes back `needs_eyes`, reason `sufficient 0.41`. Open the screenshot,
   find the reply arrow, `resume <session> --eyes 7`.
5. The user gets one confirmation window at the send, showing the exact message
   text. They click it.
6. Status `completed`. Report: the reply was sent, and quote the body that was
   actually sent.

That is three of your turns for a seven-step task, and one of them was a
question. If you are taking twenty turns, re-read this file.
