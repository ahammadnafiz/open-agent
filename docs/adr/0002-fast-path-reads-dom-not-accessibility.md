# 2. The fast path reads the DOM, not the accessibility tree

Date: 2026-09-18

## Status

Accepted. Supersedes the accessibility-only fast path assumed when the two-tier
architecture was chosen.

**Reasoning corrected 2026-09-18** — see [Correction](#correction) at the end.
The decision stands; the stated cause was wrong.

## Context

The architecture depends on reading the current screen as text cheaply, so that
a System One model can select the target element in ~400ms instead of sending a
screenshot to a vision model for 2-4s.

The macOS accessibility API was assumed to be that text source. Measurement on
this machine showed it is not, for the case that matters:

- A Safari window showing a Wikipedia article exposed 26 accessibility nodes,
  all browser chrome: Go back, Go forward, Page Menu, Tab Group picker. No page
  content of any kind was reachable.
- `AXManualAccessibility` was rejected (-25205) and `AXEnhancedUserInterface`
  was rejected (-25208).

WebKit and Gecko build their accessibility trees lazily and only for a
registered assistive-technology client. A process holding the Accessibility TCC
permission is not sufficient to trigger this.

The browsers' own automation protocols were then measured. Zen, launched with
`--remote-debugging-port`, accepted a WebDriver BiDi session over WebSocket,
navigated on command, and returned 3,684 DOM nodes with 600+ labelled
actionable elements from the same Wikipedia page that accessibility showed as
empty.

## Decision

The fast path reads web content from the browser's own automation protocol
(WebDriver BiDi for Gecko, the DevTools Protocol for Chromium) and reads native
application UI from the accessibility API. Both produce a list of labelled,
addressable elements, which is what the selection step consumes. The rest of
the architecture is unchanged.

Candidate elements are reduced before selection by a deterministic filter:
rendered, non-zero size, within the viewport, and carrying a label. Measured on
real pages this reduces 913 elements to 42, 227 to 127, and 217 to 44 — all
below the 255-option ceiling of a single Choice question, so no chunking or
ranking stage is required.

## Consequences

The agent must own browser launch. It cannot drive a window the user opened by
hand, because the debug port can only be enabled at process start. This is a
real constraint on the product and is dealt with separately.

Element identity improves rather than degrades. The DOM offers stable selectors,
ARIA roles, real text, and load-state events, none of which the accessibility
tree was going to provide for web content.

Two element sources must be maintained rather than one. They are not abstracted
behind a common interface beyond the shape the selection step consumes, because
they are not interchangeable — a target is either in a browser or it is not.

Vision escalation remains necessary for canvas, video, image-only controls, and
any native application with a poor accessibility tree.

## Correction

*Added 2026-09-18, after controlled measurement.*

The Context above states that browser web content is unreachable through the
accessibility API. **That is false.** The measurement behind it was incomplete:
the probe walked the window tree and never touched the application element.

A controlled A/B on Chrome, isolated profile, identical probes differing by one
call:

```
control — walk the window tree for 16s, never touch the app element
  t=6.0s   37 nodes   AXWebArea=0  AXLink=0  AXStaticText=0
  AXWebArea never appeared

test — identical, plus ONE read of kAXRoleAttribute on the APPLICATION element
  t=6.0s   96 nodes   AXWebArea=1  AXLink=3  AXTextField=2  AXCheckBox=1
  "Email address", "Password", "Remember me", "Create account", "Cancel"
```

A single accessibility read on the application element triggers Chromium to
build its web tree. This matches Chromium's source: `accessibilityRole` on
`chrome_browser_application_mac.mm` calls `CreateScopedModeForProcess(kAXModeBasic)`.
Firefox 121+ behaves the same way. WebKit self-activates on first client query.
`--force-renderer-accessibility` also works and additionally freezes the mode on.

So the trees can be forced. The decision does not change, because the reason to
prefer the DOM turns out to be **latency, not impossibility**:

- Cross-process accessibility calls cost **0.1–0.4 ms each**.
- A page with ~2,400 DOM nodes produces ~2,815 accessibility nodes, requiring
  ~8,445 calls — **about 1,000 ms**.
- A heavy application page at 20–50k nodes lands in the **10–30 second** range.
- The cost is the target process serialising its tree, not IPC round trips, so
  batching recovers only about 2×.

Against that, one `script.evaluate` over WebDriver BiDi returns the whole
filtered candidate list in well under 100 ms. Measured end to end on real pages,
DOM extraction plus Jev selection runs at a **552 ms median**.

The undocumented SPI `AXUIElementCopyHierarchy` (present in HIServices, in no
header) replaces those 8,445 calls with one and lands around 500–650 ms. It does
not cross process boundaries, which conveniently detects the chrome-to-content
edge for free. It carries no availability guarantee and is unusable on the App
Store, so it is not adopted here — but it is the right escape hatch if AX ever
has to carry web content.

**What this changes in practice:** the application-element read is now performed
on every app before observation, because it costs one call and is what makes
Electron, Chromium, and Gecko trees exist at all. That is a perception-layer
requirement, not a browser-specific hack.
