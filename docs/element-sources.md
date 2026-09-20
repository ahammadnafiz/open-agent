# Element Sources

How the harness reads the screen as text. Two sources, chosen per step: WebDriver
BiDi for web content, Accessibility for native applications.

Everything in this document was verified on macOS 26.6.2 with Zen, Chrome,
Safari, Finder and Notes. Measurements are from that machine.

---

## 0. Why two sources

The obvious design is one source: the macOS Accessibility API, which exposes
every application uniformly. **It does not work for web content**, and that was
established by measurement, not assumption:

```
Safari window showing en.wikipedia.org/wiki/Accessibility
  AX nodes reachable:  26
  roles:               AXButton ×12, AXGroup ×7, AXStaticText ×12, AXToolbar, AXWindow
  actionable found:    "Go back", "Go forward", "Page Menu", "Tab Group picker"
  page content:        NONE
  AXWebArea present:   NO

  AXManualAccessibility    → rejected, -25205 (invalid element)
  AXEnhancedUserInterface  → rejected, -25208 (attribute unsupported)
```

**That probe was incomplete, and its conclusion is half wrong.** It walked the
window tree and never touched the *application* element. A single read of
`kAXRoleAttribute` on the application element makes Chromium build its web tree —
measured A/B, 37 nodes → 96 nodes with `AXWebArea`, links, text fields and
buttons. Firefox 121+ behaves identically; WebKit self-activates on first query.

The trees can be forced. The DOM is still preferred, for **latency**: cross-process
accessibility calls cost 0.1–0.4 ms each, so a real page's ~8,445 calls run about
**1,000 ms**, and a heavy page 10–30 s. One `script.evaluate` returns the same
information in under 100 ms.

The same page through the browser's automation protocol returned **3,684 DOM
nodes and 600+ labelled actionable elements**.

Full reasoning and the corrected measurement:
[ADR 0002](./adr/0002-fast-path-reads-dom-not-accessibility.md).

**Consequence for every source:** read `kAXRoleAttribute` on the application
element before observing anything, and set `AXManualAccessibility` on it for
Electron apps (then wait out the hard-coded ~2 s debounce). One call each; it is
what makes Chromium, Gecko and Electron trees exist at all.

---

## 1. WebDriver BiDi (web)

### 1.1 Why BiDi and not CDP

Gecko removed CDP support in Firefox 129. Zen is Gecko-based, so **BiDi is the
only option** for the primary browser. Chromium keeps CDP; if Chrome support is
added it needs a separate client, not a config flag.

Verified on this machine:

```
$ zen --remote-debugging-port 9333 --profile <agent> --headless --no-remote
$ lsof -nP -iTCP:9333 -sTCP:LISTEN
  zen  51209  nafiz  8u  IPv4  TCP 127.0.0.1:9333 (LISTEN)
```

The port listens but **does not serve CDP's HTTP endpoints** — `/json/version`
returns nothing. BiDi is a WebSocket protocol at `ws://127.0.0.1:<port>/session`.
Probing for `/json/version` and concluding "no remote debugging" is the trap;
it cost an hour during design.

### 1.2 Launch

```swift
// The debug port can ONLY be enabled at process start. This is why the agent
// owns a dedicated profile — it cannot attach to a browser the user opened.
let proc = Process()
proc.executableURL = URL(filePath: "/Applications/Zen.app/Contents/MacOS/zen")
proc.arguments = [
    "--remote-debugging-port", String(Constants.Browser.bidiPort),   // 9333
    "--profile", Constants.Browser.agentProfilePath,
    "--no-remote",          // do not hand off to the user's running instance
]
try proc.run()
```

`--no-remote` is required. Without it Gecko hands the command to the already-
running Zen and your new process exits immediately, silently, having done
nothing — the agent then waits forever for a port that never opens.

Readiness is a connect-retry loop on the WebSocket, not a fixed sleep. Cold start
measured at 5–7 s; a fixed `sleep` either wastes time or races.

### 1.3 Session

```swift
// Minimal BiDi client over URLSessionWebSocketTask. No dependency required.
actor BiDiClient {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

    func send(_ method: String, _ params: JSON) async throws -> JSON {
        nextID += 1
        let id = nextID
        try await socket.send(.string(encode(["id": id, "method": method, "params": params])))
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    // A receive loop matches inbound frames by `id` and resumes the continuation.
    // Frames WITHOUT an `id` are events (browsingContext.load, log.entryAdded);
    // route those to a stream, never to the pending table.
}
```

Handshake, all verified working:

```
session.new                { capabilities: {} }                            → OK
browsingContext.getTree    {}                                              → contexts[0].context
browsingContext.navigate   { context, url, wait: "complete" }              → complete
script.evaluate            { expression, target: {context}, awaitPromise } → value
```

`wait: "complete"` blocks until the load event. Do not implement a navigation
poll loop; BiDi already has the lifecycle.

### 1.4 Observation

One `script.evaluate` per observation. Returns a compact JSON array — never the
DOM itself.

```javascript
(() => {
  const SEL = 'a,button,input,textarea,select,summary,' +
              '[role=button],[role=link],[role=textbox],[role=checkbox],' +
              '[role=tab],[role=menuitem],[contenteditable=true]';
  const vh = innerHeight, vw = innerWidth;
  const out = [];
  let idx = 0;

  // `document.querySelectorAll` does NOT cross a shadow boundary. Any app built
  // on web components — Outlook Web, YouTube, most design systems — returns a
  // near-empty candidate list from a plain query, which reads to the agent as
  // "nothing actionable here" rather than as an error. That is the same silent
  // -failure shape as AXWindows.first and minimumTextHeight; see §2.2 and §2.5.
  //
  // Finding shadow hosts requires visiting every element, so this walks '*'
  // rather than SEL. Measured cost is in the noise at the page sizes seen so
  // far (3,684 nodes on the Wikipedia fixture); re-measure if a page is slow.
  const collect = (root, acc) => {
    for (const e of root.querySelectorAll('*')) {
      if (e.matches(SEL)) acc.push(e);
      if (e.shadowRoot) collect(e.shadowRoot, acc);   // open roots only
    }
    return acc;
  };

  // A CLOSED shadow root cannot be pierced from script, by design. Those
  // subtrees are invisible to tier 1 and fall through to tier 3/4, which is
  // exactly what the gradient is for — ADR 0005, and ADR 0007 for execution.
  for (const e of collect(document, [])) {
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;                  // rendered
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') continue;
    if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) continue;  // in viewport

    const label = (
      e.getAttribute('aria-label') || e.innerText || e.value ||
      e.placeholder || e.title || e.alt || ''
    ).trim().replace(/\s+/g, ' ').slice(0, 80);
    if (!label) continue;                                        // labelled

    e.setAttribute('data-agent-id', 'e' + idx);                  // stable handle
    out.push({
      id: 'e' + idx++,
      role: e.getAttribute('role') || e.tagName.toLowerCase(),
      label,
      enabled: !e.disabled && e.getAttribute('aria-disabled') !== 'true',
      submit: e.type === 'submit' || e.getAttribute('role') === 'button' && e.form != null,
      // What pressing Enter in this element would activate. A text field does
      // not carry the label of the button its form submits to, and that label
      // is the only thing standing between `pressKey(.enter)` in a To-field and
      // an unconfirmed send — ADR 0008.
      submitLabel: (e.form && e.form.querySelector(
        'button:not([type=button]),[type=submit]'))?.innerText?.trim().slice(0, 80) || '',
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height)
    });
    if (out.length >= 255) break;                                // hard ceiling
  }
  return JSON.stringify({ url: location.href, title: document.title, elements: out });
})()
```

`data-agent-id` gives a handle that survives between observation and action
without holding a BiDi remote-object reference across calls. It is rewritten on
every observation, so a re-render invalidates nothing — **always observe
immediately before acting**, never reuse an id across steps.

`break` at 255 is a last-resort guard. It should never fire; if it does, the
filter is wrong and `CandidateFilter` raises rather than silently truncating.
Truncation would drop the correct target with nobody noticing.

### 1.5 Measured reduction

| Page | matched selector | in viewport | + labelled | ≤255 |
|---|---|---|---|---|
| en.wikipedia.org/wiki/Accessibility | 913 | 45 | **42** | ✓ |
| news.ycombinator.com | 227 | 147 | **127** | ✓ |
| github.com/typesafe-ai | 217 | 45 | **44** | ✓ |

Worst observed 127. No chunking or pre-ranking stage is required, and none
should be built speculatively.

### 1.6 Execution

```swift
// click — dispatch on the element, not at a coordinate
try await send("script.callFunction", [
    "functionDeclaration": "el => el.click()",
    "arguments": [["sharedId": handle]],
    "target": ["context": ctx],
    "awaitPromise": true,
])

// type — REAL key events. Assigning .value directly does not fire the
// input/change listeners that React and every modern web app depend on;
// the field looks filled and the app never sees it.
try await send("input.performActions", [
    "context": ctx,
    "actions": [[
        "type": "key", "id": "kb",
        "actions": text.flatMap { c in [
            ["type": "keyDown", "value": String(c)],
            ["type": "keyUp",   "value": String(c)],
        ]},
    ]],
])

// navigate
try await send("browsingContext.navigate",
               ["context": ctx, "url": url, "wait": "complete"])
```

---

## 2. Accessibility (native)

### 2.1 Trust

```swift
guard AXIsProcessTrusted() else { … }
```

Verified behaviour worth knowing, because it produces a confusing failure:

- **Listing processes needs no permission.** `System Events → get name of every
  process` succeeds while untrusted, which makes it look like AX works.
- **Inspecting UI elements does.** Every `AXUIElementCopyAttributeValue` returns
  `-25211 (APIDisabled)` until the binary is granted Accessibility.
- **The grant is per-binary.** A freshly compiled executable is untrusted even
  when run from a granted terminal. The shipped `.app` must be granted once;
  during development the `Probe` binary needs its own grant.

Call `AXIsProcessTrustedWithOptions` with the prompt option on first run.

### 2.2 Picking the window — the bug that hides everything

**Never use `AXWindows.first`.** For Finder it is the **desktop** — an `AXGroup`
titled `"desktop"` with 2 nodes and no controls. A probe built on it reports the
application as having an empty accessibility tree, which is indistinguishable
from the app genuinely being AX-blind.

This cost several hours during design and produced a wrong conclusion that
reached the spec. The measured difference on identical live windows:

| App | via `AXWindows.first` | via `AXFocusedWindow` |
|---|---|---|
| Finder | **2 nodes**, 0 pressable | **909 nodes**, 116 pressable, 91 labelled |
| System Settings | 0 nodes | **161 nodes**, 23 pressable, 16 labelled |
| Cursor | 0 nodes | **2,017 nodes**, 120 pressable |

Resolution order, with the app activated first so "focused" means something:

```swift
app.activate()                                   // else AXFocusedWindow is stale
_ = str(ax, kAXRoleAttribute)                    // trigger Chromium / Gecko a11y
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
// ^ Electron only; wait out its hard-coded ~2s debounce if this succeeds

for _ in 1...8 {
    if let f = copy(ax, kAXFocusedWindowAttribute) { return f }   // 1st choice
    if let m = copy(ax, kAXMainWindowAttribute)    { return m }   // 2nd
    // 3rd: largest window by area — never simply the first
    if let ws = copy(ax, kAXWindowsAttribute) as? [AXUIElement] {
        return ws.compactMap { w in frame(w).map { (w, $0.width * $0.height) } }
                 .max(by: { $0.1 < $1.1 })?.0
    }
    sleep(0.4)                                   // AXWindows flakes empty
}
```

### 2.3 Measured coverage, live windows

| App | kind | nodes | pressable | labelled | verdict |
|---|---|---|---|---|---|
| **Finder** | Cocoa | 909 | 116 | **91 (78%)** | tier 2 works |
| **System Settings** | Cocoa | 161 | 23 | **16 (70%)** | tier 2 works |
| TextEdit | Cocoa | 18 | 5 | 1 (20%) | few controls to begin with |
| **Cursor** | Electron | 2,017 | 120 | **5 (4%)** | tree exists, labels do not |
| **ghostty** | GPU-rendered | 12 | **0** | 0 (0%) | tier 3/4 only, permanently |

**The Electron unlock works and is not enough.** `AXManualAccessibility` took
Cursor from 0 nodes to 2,017 — the mechanism is confirmed. But only **4% of its
pressable elements carry a label**, so there is almost nothing for a text model
to select from. Electron apps have a tree and still need tier 3/4. This closes
Open Question Q2: the unlock is worth performing, and it does not promote Electron
to tier 2.

**ghostty exposes 12 nodes and zero pressable elements** with a live, focused,
on-screen window. That is the floor, and it is what tier 3/4 exists for.

### 2.2 Observation

```swift
// Start from AXWindows, NOT from the application element's AXChildren.
//
// The application's children are the MENU BAR. Walking from there returned
// 10,804 menu items for Zen and 527 for Chrome, and zero window content —
// an hour of confusion during design.
guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement],
      let window = windows.first else { throw AXError.noWindow }
```

Walk recursively, keeping any element with a non-empty label and at least one
action:

```swift
func walk(_ el: AXUIElement, path: [Int], into out: inout [Element]) {
    guard out.count < Constants.Jev.maxCandidates else { return }
    let role    = copy(el, kAXRoleAttribute)  as? String ?? "?"
    let label   = (copy(el, kAXTitleAttribute) as? String)
               ?? (copy(el, kAXDescriptionAttribute) as? String)
               ?? (copy(el, kAXValueAttribute) as? String) ?? ""
    var actions: CFArray?
    AXUIElementCopyActionNames(el, &actions)
    let acts = (actions as? [String]) ?? []

    if !label.isEmpty, !acts.isEmpty {
        out.append(Element(ref: .ax(path: path, role: role, label: label), …))
    }
    for (i, child) in children(el).enumerated() {
        walk(child, path: path + [i], into: &out)
    }
}
```

**`path` is stable only within one observation.** It is an index chain from the
window root, and any layout change invalidates it. Re-observe immediately before
acting — never carry a path across steps.

Every walk carries a wall-clock deadline and a node cap. Zen's menu tree is
10,804 nodes and takes 3.76 s to traverse; without a deadline a pathological
tree blows the step budget on its own.

### 2.3 Measured

| App | nodes | walk | labelled + actionable | AXPress-able |
|---|---|---|---|---|
| Finder | 174 | 0.11 s | 33 | 11 |
| Notes | 44 | 0.04 s | 12 | 10 |
| Safari (chrome only) | 26 | 0.01 s | 4 | 4 |
| **Cursor** (Electron) | — | — | **no AX window** | — |
| **ghostty** (GPU-rendered) | — | — | **no AX window** | — |

Real Cocoa apps expose rich, fast trees with usable actions — Finder exposed real
filenames with `AXOpen`, Notes exposed "New Note", "Format", "Checklist" with
`AXPress`.

**Electron and GPU-rendered applications expose nothing.** Electron can sometimes
be unlocked by setting `AXManualAccessibility` on the *application* element
(distinct from the Safari attempt in §0, which targeted a WebKit view and was
rejected). GPU-rendered apps — terminals, games, canvas editors — cannot be
unlocked at all and are **vision-only, permanently**. This is Open Question Q2.

### 2.4 Execution

```swift
// click
AXUIElementPerformAction(el, kAXPressAction as CFString)

// type — try the attribute, fall back to key synthesis
if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) != .success {
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    synthesizeKeystrokes(text)   // CGEvent, requires the element focused
}
```

Check `AXUIElementCopyActionNames` before acting. Measured, elements carry
different action sets — Finder items offer `AXOpen, AXShowMenu` but not
`AXPress`; a window offers only `AXRaise`. Assuming `AXPress` is universal fails
silently on exactly the elements that matter.

---

## 2.5 Screen capture + OCR (tier 3 — anything)

The universal fallback. Works on any pixels: canvas, games, terminals, Electron
apps with no tree, video. Produces `label + bbox`, never `role`.

**No Apple framework returns `role` from pixels.** All 34 Vision request types
were benchmarked — rectangles, contours, saliency, document segmentation,
foreground masks. None knows what a button is. `DetectDocumentSegmentationRequest`
returns **0 regions** on a screenshot, because a screenshot is not paper.

### Capture

```swift
// macOS 26. Cache the SCWindow — enumeration, not capture, is what costs.
let shot = try await SCScreenshotManager.captureScreenshot(
    contentFilter: filter, configuration: config)      // 7–17 ms
```

Occluded, minimized and hidden windows all capture correctly. Legacy
`CGWindowListCreateImage` returns `NULL` for minimized and hidden — do not use it.
Transient `-3811` errors occur even on windows that just captured; retry with
~250 ms backoff. Requires Screen Recording TCC; there is no Info.plist key for it.
A plain CLI binary must touch `CGMainDisplayID()` early or `SCScreenshotManager`
aborts with `CGS_REQUIRE_INIT`.

### Recognition — three settings decide whether this works at all

```swift
var r = RecognizeTextRequest()
r.recognitionLevel        = .accurate     // NOT .fast — see below
r.minimumTextHeightFraction = 0           // NOT the default — see below
r.usesLanguageCorrection  = false         // "corrects" filenames and labels
r.recognitionLanguages    = [Locale.Language(identifier: "en-US")]
```

**`minimumTextHeightFraction` defaults to `0.03125`, which returns ZERO
observations on a Retina screenshot in `.fast` mode.** Measured sweep at
2880×1800, where UI text is ~26 px ≈ 0.0144 of height:

| value | = px | observations |
|---|---|---|
| 0.0 | 0 | **86** |
| 0.010 | 18 | 81 |
| 0.0144 | 26 | **1** |
| 0.03125 *(default)* | 56 | **0** |

Apple's ObjC header claims the default is 0.0; the Swift struct measurably
disagrees. This is a silent total failure, not an error.

**Use `.accurate`.** Measured on identical real pages, `.fast` produced
`Cr8ate`, `R&ad`, `Mlcrosoft`, `Hirln`; `.accurate` produced none of them. Cost
is 368 ms against 92 ms — the budget absorbs it. `.fast` confidence is quantized
to 0.50 and carries no signal.

**Capture at native Retina scale and never downscale.** At 1× recall of known UI
labels was 21/34 and missed the entire menu bar; at 2× it was 34/34.

### The line-merge problem — a correctness bug, not a quality issue

**Vision returns *line* observations, not element observations.** Horizontally
adjacent controls merge into one box. Measured on real pages:

```
"Donate Create account Log in"          ← three separate links, one observation
"Read Edit View history :"              ← four tabs, one observation
"Hacker News new | past | comments |    ← the entire nav bar, one observation
 ask | show | jobs | submit | login"
```

A merged box has a plausible label and a centre point that lands on an arbitrary
one of the controls it spans. That is a **confidently wrong click** — the worst
failure mode available, and invisible to confidence and margin, which both read
1.00 on these.

**Splitting line observations by horizontal gap is a requirement, not an
optimisation.** Until it exists, treat every tier-3 candidate as
escalation-eligible regardless of confidence.

### Measured coverage, and why tier 3 is a supplement

Across 7 apps and 624 pressable elements:

| source | reaches |
|---|---|
| OCR alone | **25.8%** |
| accessibility labels | **62.7%** |
| **icon-only, no text anywhere** | **74.2%** |

ghostty exposes 2 elements (the window traffic lights). Chrome is 83% icon-only.
Figma's canvas exposes nothing. OCR is not the universal layer — it is the layer
that catches text the accessibility tree missed. Icon-only targets go to tier 4.

### Icon detection (tier 3b)

An ANE-resident box detector closes the icon gap without labelling anything:
**9.71 ms at imgsz 640, 57.75 ms at 1280** on this machine, versus 78 ms and
366 ms on CPU. It returns boxes with no roles and no labels, which is precisely
what Set-of-Marks needs — the vision model supplies the semantics.

Do not add a local captioner. Florence-2 over 130 icons costs **+2,940 ms**, and
OmniParser as shipped takes ~120 s per screenshot on a Mac or OOMs, because a
`do_resize=False` branch is applied only on CUDA and crops get upscaled 64×64 →
768×768. Note also its detector weights are **AGPL**, not MIT.

## 2.6 Execution without an element tree (tiers 3–4)

Tiers 1 and 2 dispatch to an element: the browser or the OS routes the effect and
no point is involved. Tiers 3 and 4 have no element to dispatch to, so actuation
is a synthesized `CGEvent` click at the centre of the target's box.

Full reasoning, and why this does not breach ADR 0001, is in
[ADR 0007](./adr/0007-captured-targets-execute-by-synthesized-event.md). The
mechanics, and the three things that must be true first:

```swift
// Screen coordinates, from a bbox captured in a known frame.
let p = CGPoint(x: bbox.midX, y: bbox.midY)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
```

1. **`provenance != .ocrLine`.** Vision returns line observations, so a box may
   span `"Donate Create account Log in"` and its centre lands on an arbitrary one
   of the three. Splitting by gap was measured impossible (§2.5). OCR boxes feed
   tier 4's marks; they are never clicked directly.
2. **The window is raised and verified on screen** via
   `CGWindowListCopyWindowInfo`. A point click hits whatever is topmost at that
   point — which, unlike every other tier, can be a different application. This
   is why Open Question Q6 is a correctness prerequisite and not a test-rig
   detail.
3. **The frame hash is in the step log.** A bbox is meaningless without the
   capture it was measured in, and a step nobody can replay is a step nobody can
   audit.

Coordinates are computed here and nowhere else. Nothing upstream — planner,
Jev, the vision model, the `Action`, the log's identity field — carries one.

---

## 3. The shared contract

Both sources produce the same `[Element]`, and the rest of the harness cannot
tell them apart:

```swift
public struct Element: Sendable, Hashable {
    public let ref: ElementRef    // .dom | .ax | .captured — see harness.md §2.1
    public let role: String
    public let label: String
    public let visionLabel: String  // tier 4's own name for it; "" otherwise. Denylist input.
    public let submitLabel: String  // what Enter here would activate; "" otherwise. ADR 0008.
    public let enabled: Bool
    public let inViewport: Bool
    public let bounds: CGRect     // filter + vision. Reaches an Action ONLY inside
                                  // `.captured`, and is turned into a point only
                                  // by CapturedExecutor at act time — ADR 0007.
}
```

They are **not** abstracted further than this. There is no plugin system and no
common driver interface, because a target is either inside a browser or it is
not — the two are never interchangeable and nothing chooses between them
dynamically beyond the one-line check in `sourceFor`.

### Description for the Jev state

```swift
func describe(_ elements: [Element]) -> String {
    elements.map { "<\($0.role)> \($0.label)\($0.enabled ? "" : " (disabled)")" }
            .joined(separator: "\n")
}
```

Compact on purpose. This string enters the Jev `state` twice per step
(`screen_before` and `screen_now`), and Jev's documented weakness is accuracy
degrading as state fills with irrelevant content. Roles and labels are what the
selection question needs; coordinates, sizes and DOM structure are not, and
adding them costs accuracy on every question in the batch.
