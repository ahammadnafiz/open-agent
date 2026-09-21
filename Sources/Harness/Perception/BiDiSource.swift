import CoreGraphics
import Foundation

/// One action from the snapshot, as the page described it.
struct SnapshotAction: Sendable {
  let id: String
  let role: String
  let label: String
  let kind: String
  let disabled: Bool
  let occluded: Bool
  let bounds: CGRect
  let value: String
  let submit: String

  init?(_ raw: [String: Any]) {
    guard let id = raw["id"] as? String,
      let role = raw["role"] as? String,
      let label = raw["label"] as? String
    else { return nil }
    self.id = id
    self.role = role
    self.label = label
    kind = (raw["kind"] as? String) ?? "click"
    disabled = (raw["disabled"] as? Bool) ?? false
    occluded = (raw["occluded"] as? Bool) ?? false
    value = (raw["value"] as? String) ?? ""
    submit = (raw["submit"] as? String) ?? ""
    let x = (raw["x"] as? Double) ?? 0
    let y = (raw["y"] as? Double) ?? 0
    let w = (raw["w"] as? Double) ?? 0
    let h = (raw["h"] as? Double) ?? 0
    bounds = CGRect(x: x, y: y, width: w, height: h)
  }
}

/// One whole observation of a page.
struct BiDiSnapshot: Sendable {
  let url: String
  let title: String
  let text: String
  let actions: [SnapshotAction]
  /// `id → fingerprint`. Compared immediately before acting, so "the page moved
  /// under me" is distinguishable from "the click missed".
  let guards: [String: String]
  let pageKey: String
  /// What the page thinks its own window is. Zero means the tab has never been
  /// laid out, and every element then fails the in-viewport test at once.
  let viewport: CGSize
  /// Counts only, for when nothing survives the filter.
  let funnel: String
  /// Total DOM nodes. Still climbing means the page is still building itself.
  let nodeCount: Int
  /// What the document says about itself: `loading`, `interactive`, `complete`.
  let readyState: String
  /// Regions the page itself marks as still filling in.
  let busy: Int
  /// The content area's origin on screen, in CSS pixels.
  let screenOrigin: CGPoint
  /// The element holding keyboard focus, as an action id. Empty when focus is
  /// on nothing the snapshot collected.
  let focusedID: String

  init(_ raw: [String: Any]) {
    url = (raw["url"] as? String) ?? ""
    focusedID = (raw["focused"] as? String) ?? ""
    title = (raw["title"] as? String) ?? ""
    text = (raw["text"] as? String) ?? ""
    pageKey = (raw["page_key"] as? String) ?? ""
    let f = (raw["funnel"] as? [String: Any]) ?? [:]
    nodeCount = (f["all"] as? Double).map { Int($0) } ?? 0
    readyState = (f["ready"] as? String) ?? "complete"
    busy = (f["busy"] as? Double).map { Int($0) } ?? 0
    funnel =
      "all=\((f["all"] as? Double).map { Int($0) } ?? -1) "
      + "a=\((f["anchors"] as? Double).map { Int($0) } ?? -1) "
      + "btn=\((f["buttons"] as? Double).map { Int($0) } ?? -1) "
      + "raw=\((f["raw"] as? Double).map { Int($0) } ?? -1) "
      + "ready=\((f["ready"] as? String) ?? "?") "
      + "busy=\((f["busy"] as? Double).map { Int($0) } ?? -1)"
    let origin = (raw["screen"] as? [String: Any]) ?? [:]
    screenOrigin = CGPoint(
      x: (origin["x"] as? Double) ?? 0, y: (origin["y"] as? Double) ?? 0)
    let size = (raw["viewport"] as? [String: Any]) ?? [:]
    viewport = CGSize(
      width: (size["w"] as? Double) ?? 0, height: (size["h"] as? Double) ?? 0)
    actions = ((raw["actions"] as? [Any]) ?? []).compactMap {
      ($0 as? [String: Any]).flatMap(SnapshotAction.init)
    }
    guards = ((raw["guards"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
  }
}

/// Tier 1 — the DOM, over WebDriver BiDi.
///
/// **One `script.evaluate` per observation.** `browser-use/jev-ultrafast`
/// measured browser protocol calls dropping from 1,092 to 101 on the same task
/// by reading the page atomically instead of resolving nodes one round trip at a
/// time. ADR 0010 adopts that design; this is the implementation.
///
/// ADR 0002 stands: the web fast path reads the DOM rather than the
/// accessibility tree, and it does so over BiDi rather than CDP, because AX on a
/// real page measured ~1,000 ms against under 100 ms for BiDi.
public actor BiDiSource: ElementSource {
  public nonisolated let kind: SourceKind = .bidi
  private let client: BiDiClient
  /// The most recent snapshot. `BiDiExecutor` re-reads it to validate a target
  /// before acting — the guards are how a stale decision is caught.
  private(set) var latest: BiDiSnapshot?

  public init(client: BiDiClient) {
    self.client = client
  }

  public func observe() async throws -> [Element] {
    let data = try await client.evaluate(SnapshotScript.source)
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BiDiError.malformedResponse("snapshot was not an object")
    }
    let snapshot = BiDiSnapshot(raw)
    latest = snapshot

    Log.debug(
      "bidi snapshot: \(snapshot.actions.count) actions on \(snapshot.url) "
        + "viewport \(Int(snapshot.viewport.width))x\(Int(snapshot.viewport.height)) "
        + snapshot.funnel)

    return snapshot.actions.map {
      Self.element(
        $0, focusedID: snapshot.focusedID, screenOrigin: snapshot.screenOrigin)
    }
  }

  /// One action, as the loop sees it.
  ///
  /// **Separated from `observe()` so it can be asserted without a browser.**
  /// The page reported `value` and `focused` from the beginning and the Swift
  /// side dropped both on the floor — the same shape of defect as `readiness()`
  /// dispatching statically to `""`, and this codebase has now written it
  /// twice. A snapshot field that nothing can prove reaches an `Element` is a
  /// snapshot field waiting to go quiet again.
  static func element(
    _ action: SnapshotAction, focusedID: String, screenOrigin: CGPoint
  ) -> Element {
    Element(
      ref: .dom(
        handle: action.id,
        selector: "\(action.role)[\(action.label)]",
        label: action.label,
        submitLabel: action.submit
      ),
      role: action.role,
      label: action.label,
      enabled: !action.disabled,
      // What the field holds, which is what makes a filled one distinguishable
      // from an empty one, and where the keyboard is, which is what makes a
      // click into that field visible at all. See `Element.value`.
      value: action.value,
      focused: !focusedID.isEmpty && action.id == focusedID,
      // An occluded control is in the viewport and cannot be clicked: a modal
      // or a cookie banner is over it. Reported as out-of-viewport so the
      // deterministic filter drops it, rather than offering a candidate that
      // would silently click the overlay instead.
      inViewport: !action.occluded,
      // Offset into screen space, so `bounds` means the same thing here as it
      // does for the accessibility tier — which is what the overlay converts
      // from. The executor is untouched: it recomputes its click point from
      // the element's own rect at act time, in the page coordinates
      // `input.performActions` expects.
      bounds: action.bounds.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
    )
  }

  public nonisolated var reportsReadiness: Bool { true }

  public func readiness() async -> String {
    // **A document that says it is still loading is not settled, however still
    // it looks.** Instagram's inbox parks at ~507 nodes with `readyState:
    // loading` for seconds — stable, and nowhere near finished. Reporting the
    // state rather than a count lets the caller refuse to settle on it.
    guard let latest else { return "" }
    return Self.readiness(
      readyState: latest.readyState, busy: latest.busy, nodeCount: latest.nodeCount)
  }

  /// The rule itself, separated from the snapshot so it can be asserted
  /// without a browser attached.
  static func readiness(readyState: String, busy: Int, nodeCount: Int) -> String {
    // **"Still loading" and "has a spinner on it" are not the same claim, and
    // treating them as one cost a second and a half on every step.** A
    // document that has not finished is unarguable. A busy marker is not.
    //
    // X's composer character counter is a `role="progressbar"`
    // (`data-testid="countdown-circle"`). It appears on the first keystroke
    // and stays for the rest of the composing session, so from the moment
    // anything is typed the page claims to be loading and never stops. The
    // step after a type is the one that clicks Post, so that step paid the
    // whole budget twice over — every settle poll hit the caller's reset
    // branch and stability could never accumulate.
    //
    // So they are reported apart, and the caller decides how much each one is
    // worth. `loading` still stops everything. `busy` carries the node count
    // with it, because a caller that has waited long enough for a spinner
    // that is never going to clear still needs the page's size to judge it.
    guard readyState == "complete" else { return "loading" }
    guard busy == 0 else { return "busy:\(nodeCount)" }
    return "\(nodeCount)"
  }

  /// The candidate holding keyboard focus, when the page reports one.
  ///
  /// This is what makes `Enter` after `type` deterministic: the field just
  /// typed into is the field focus is in, whatever its accessible name has
  /// become. Selection by name cannot answer that question — the name changed
  /// the moment the text landed.
  public func focused(among elements: [Element]) async -> Element? {
    guard let handle = latest?.focusedID, !handle.isEmpty else { return nil }
    return elements.first { element in
      if case .dom(let candidate, _, _, _) = element.ref { return candidate == handle }
      return false
    }
  }

  /// The snapshot's own fingerprint of the page.
  func pageKey() -> String { latest?.pageKey ?? "" }

  /// Whether a target still looks the way it did when it was chosen.
  ///
  /// A guard mismatch means the page changed between the decision and the act.
  /// Clicking anyway is how an agent presses the button that moved into the
  /// place the old one used to be.
  func isStale(_ handle: String, expecting fingerprint: String?) -> Bool {
    guard let fingerprint else { return false }
    return latest?.guards[handle] != fingerprint
  }

  func guardFingerprint(_ handle: String) -> String? { latest?.guards[handle] }
}
