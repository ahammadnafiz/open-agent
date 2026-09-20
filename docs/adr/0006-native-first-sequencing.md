# 6. Build native-first, browser second

Date: 2026-09-18

## Status

Accepted

## Context

The architecture supports four perception tiers and the original scope was to
build browser and native support together, driven by a reference task that lived
entirely in a browser: open Zen, go to an X profile, compose a post, publish it.

Measurement across 32 hand-labelled intents reversed the expected ordering.

| Tier | Source | Intents | Raw hit | Gated | Gate precision | Latency |
|---|---|---|---|---|---|---|
| 1 | DOM via WebDriver BiDi | 16 | 81% | 69% | 11/11 | 552 ms |
| 2 | macOS Accessibility | 16 | **100%** | **100%** | **16/16** | 473 ms |

Tier 2 outperformed tier 1 on every measure. The cause is not incidental:
accessibility labels are authored to be spoken aloud, so they are short, unique
and semantic — `Time Machine`, `Transfer or Reset`, `NDA - Ahammad Nafiz.pdf`.
DOM labels on real pages are noisy with navigation chrome, repeated links,
decorative anchors and advertising frames. Selections in the tier-2 run included
real semantic jumps: *"erase this Mac and start over"* resolved to
`Transfer or Reset`, and *"the ICCIT conference paper"* was picked out of 91
filenames.

The two tiers also differ sharply in what they cost to build and in what they
risk.

Tier 2 needs the accessibility source, an executor built on `AXPress`, and a
window guard. Nothing else. Tier 1 additionally needs a browser lifecycle, a
dedicated agent profile with its own logins, a WebDriver BiDi WebSocket client,
and it carries the one unresolved risk in the project: whether X.com tolerates a
BiDi-driven browser at all. That question has never been tested and it governs
the original reference task.

Building both together means nothing ships until roughly twice the surface works,
and the first thing to ship would depend on the least certain component.

## Decision

Build tiers 2 and 4 first. Browser support follows as tier 1 once the loop,
safety gate, recovery ladder and HUD are working against native applications.

The v1 reference task changes accordingly, and is chosen to exercise every
mechanism that matters rather than to be impressive:

> *"Open Mail, reply to the most recent message from <person> saying I'll get
> back to them tomorrow, and send it."*

This touches accessibility navigation across an application, on-device
composition through Apple Foundation Models, and — at `send` — the deterministic
irreversible gate and the confirmation dialog. The publish-to-X task returns as
the tier-1 reference task when browser support lands.

## Consequences

**The first shippable version covers most of a Mac.** Finder, Mail, Notes, Music,
System Settings, Preview, TextEdit, Calendar, Reminders — every Cocoa application
that builds an accessibility tree, which measurement put at 70–78% of pressable
elements labelled.

**Four sources of risk and work are deferred rather than solved:** browser
lifecycle and profile management, the BiDi client, a second login for every site
the agent must reach, and X.com's tolerance of automation. None of them can
block a release that does not include them.

**The Electron and GPU-rendered gap becomes visible sooner.** Cursor unlocks to
2,017 accessibility nodes with only 4% labelled; ghostty exposes zero pressable
elements. Under native-first these are the *first* applications a user will try
that do not work well, rather than an edge case discovered late. Both fall to
tier 4, which measured 83%, at 4.8 s per step.

**Nothing measured is discarded.** Tier 1 is already proven at 69% gated with
100% precision, and the BiDi client is already known to work end to end against
Zen. Deferring it costs nothing but time.

**Task 0.1 — X.com under BiDi — is no longer a Phase 0 blocker.** It moves to the
browser phase, where it belongs, and can be run cheaply at any point before that
work begins.
