import ApplicationServices
import CoreGraphics
import Foundation

/// Tier 2 — the accessibility tree.
///
/// Measured the best of the four tiers: **100% hit, 100% gated, 100% gate
/// precision, 473 ms**, because accessibility labels are clean and semantic
/// (`Time Machine`, `NDA - Ahammad Nafiz.pdf`) where DOM labels on real pages
/// are noisy with repeated nav links and decorative anchors.
///
/// Three mistakes are designed out rather than commented around, because each
/// one cost hours during design and two of them produce a *wrong conclusion*
/// rather than an error:
///
/// 1. **Never `AXWindows.first`.** For Finder that is the desktop — an `AXGroup`
///    titled "desktop" with 2 nodes and no controls. A probe built on it reports
///    the application as AX-blind, which is indistinguishable from the app
///    genuinely being AX-blind. Measured on identical live windows: Finder gave
///    2 nodes via `.first` and **909** via `AXFocusedWindow`.
/// 2. **Never walk from the application element's children.** Those are the
///    *menu bar*: 10,804 menu items for Zen, 527 for Chrome, and zero window
///    content.
/// 3. **Never trust a single `AXWindows` read.** It intermittently returns an
///    empty array for windows that demonstrably exist — Notes and Cursor
///    returned 0 after 8 retries over 3.2 s, while Zen and Finder returned on
///    the first try.
public struct AXSource: ElementSource {
  public let kind: SourceKind = .ax
  public let pid: pid_t
  public let appName: String

  public init(pid: pid_t, appName: String) {
    self.pid = pid
    self.appName = appName
  }

  /// Direct construction, for tests that need a registry rather than a live
  /// application.
  ///
  /// Deliberately not `public`: nothing outside the package should hold a
  /// source for an app it has not resolved, because the resolution is what
  /// proves the app is running and on screen.
  init(appName: String, pid: pid_t) {
    self.appName = appName
    self.pid = pid
  }

  public init(appName: String) throws {
    self.pid = try WindowGuard.pid(forApp: appName)
    self.appName = appName
  }

  public func observe() async throws -> [Element] {
    guard AXPrimitives.isTrusted() else {
      throw PerceptionError.accessibilityNotTrusted
    }
    // A minimized or off-Space window observes as EMPTY, not as an error.
    // Failing here is the difference between "I cannot see that window" and
    // "that window has nothing in it" — Open Question Q6.
    try WindowGuard.requireVisibleWindow(pid: pid, app: appName)

    for attempt in 0..<Constants.AX.windowRetries {
      if let elements = attemptObservation() { return elements }
      if attempt < Constants.AX.windowRetries - 1 {
        try await Task.sleep(for: Constants.AX.windowRetryDelay)
      }
    }
    throw PerceptionError.noWindow(app: appName)
  }

  /// One synchronous attempt. Kept whole so no `AXUIElement` is ever held
  /// across a suspension point — they are not `Sendable` and must not escape.
  private func attemptObservation() -> [Element]? {
    let app = AXUIElementCreateApplication(pid)

    // Reading a cheap attribute on the APPLICATION element is what triggers
    // Chromium and Gecko to build their accessibility trees at all. Without
    // it a browser reports almost nothing.
    _ = AXPrimitives.string(app, kAXRoleAttribute as String)

    // Electron only. Measured: took Cursor from 0 nodes to 2,017. Rejected
    // by Chrome, Safari, Zen and Finder — the expected Electron-only
    // signature. The unlock is debounced ~2 s inside Electron itself, so the
    // result lands on a later observation, not this one. Worth performing
    // and NOT worth waiting for: only 4% of Cursor's pressable elements
    // carry a label, so Electron has a tree and still needs tiers 3–4.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    guard let window = resolveWindow(app: app) else { return nil }

    var elements: [Element] = []
    var visited = 0
    let deadline = ContinuousClock.now + Constants.AX.walkDeadline
    walk(window, path: [], into: &elements, visited: &visited, deadline: deadline)

    // An empty result is a failed attempt, not a valid observation — that is
    // exactly the case the retry loop exists for.
    return elements.isEmpty ? nil : elements
  }

  /// Resolution order, never `AXWindows.first`.
  private func resolveWindow(app: AXUIElement) -> AXUIElement? {
    if let focused = AXPrimitives.copyValue(app, kAXFocusedWindowAttribute as String) {
      return (focused as! AXUIElement)
    }
    if let main = AXPrimitives.copyValue(app, kAXMainWindowAttribute as String) {
      return (main as! AXUIElement)
    }
    // Third choice: the largest window by area. Never simply the first —
    // for Finder the first is the desktop.
    let windows = AXPrimitives.copyValue(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    return
      windows
      .compactMap { window in AXPrimitives.frame(window).map { (window, $0.area) } }
      .max(by: { $0.1 < $1.1 })?.0
  }

  /// Depth-first, keeping anything with a non-empty label **and** at least one
  /// action.
  ///
  /// Both halves matter. A label with no action is a static string; an action
  /// with no label is an icon nothing can denylist, and it belongs to tier 4.
  ///
  /// Every walk carries a wall-clock deadline *and* a node cap. Zen's menu tree
  /// alone is 10,804 nodes and takes 3.76 s; without a deadline a pathological
  /// tree blows the entire step budget on its own.
  private func walk(
    _ element: AXUIElement,
    path: [Int],
    into out: inout [Element],
    visited: inout Int,
    deadline: ContinuousClock.Instant
  ) {
    guard visited < Constants.AX.maxNodes else { return }
    guard out.count < Constants.Jev.maxCandidates else { return }
    guard ContinuousClock.now < deadline else { return }
    visited += 1

    let role = AXPrimitives.string(element, kAXRoleAttribute as String) ?? "?"
    let label = AXPrimitives.label(element)
    let actions = AXPrimitives.actions(element)

    if !label.isEmpty, !actions.isEmpty {
      let frame = AXPrimitives.frame(element) ?? .zero
      let enabled = AXPrimitives.bool(element, kAXEnabledAttribute as String) ?? true
      out.append(
        Element(
          ref: .ax(path: path, role: role, label: label),
          role: role,
          label: label,
          enabled: enabled,
          // AX only reports elements the window actually lays out, and
          // the window itself was proven on screen above. A zero frame
          // is the one case that is genuinely not rendered.
          inViewport: frame.area > 0,
          bounds: frame
        )
      )
    }

    for (index, child) in AXPrimitives.children(element).enumerated() {
      walk(child, path: path + [index], into: &out, visited: &visited, deadline: deadline)
    }
  }

  /// Re-resolves an `.ax` path to a live element.
  ///
  /// **`path` is stable only within one observation.** It is an index chain
  /// from the window root and any layout change invalidates it, so this is
  /// called immediately before acting and never carried across steps.
  /// The candidate that currently holds keyboard focus, if it is one of them.
  ///
  /// **A keystroke goes to the focused element.** ADR 0008 says so in the
  /// declaration itself — *"target is the focused element"* — so asking a model
  /// to *choose* it from a list is both unnecessary and worse. The system knows
  /// the answer exactly; the model only has an opinion, and when that opinion
  /// falls under the selection floor it becomes an escalation a human has to
  /// answer by hand. Measured on WhatsApp: `pressKey enter` after a successful
  /// `type` escalated at 0.61 confidence, to pick the field that had just been
  /// typed into.
  ///
  /// This also preserves the property ADR 0008 leans on. The focused element's
  /// label is what `LabelDenylist` inspects for `enter` — the ADR's stated
  /// mitigation for native targets, where no submit button is computable — and
  /// that check only means anything if the element really is the focused one.
  /// Selecting by guess weakened exactly the input the guess was feeding.
  ///
  /// Returns `nil` when focus is elsewhere or cannot be read, which leaves the
  /// ordinary selection path to handle it.
  public func focused(among elements: [Element]) -> Element? {
    var raw: CFTypeRef?
    let app = AXUIElementCreateApplication(pid)
    let focusedKey = kAXFocusedUIElementAttribute as CFString
    guard AXUIElementCopyAttributeValue(app, focusedKey, &raw) == .success,
      let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let target = unsafeBitCast(value, to: AXUIElement.self)

    for element in elements {
      guard case .ax(let path, _, _) = element.ref, let candidate = resolve(path: path) else {
        continue
      }
      if CFEqual(candidate, target) { return element }
    }
    return nil
  }

  func resolve(path: [Int]) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard var current = resolveWindow(app: app) else { return nil }
    for index in path {
      let children = AXPrimitives.children(current)
      guard children.indices.contains(index) else { return nil }
      current = children[index]
    }
    return current
  }
}
