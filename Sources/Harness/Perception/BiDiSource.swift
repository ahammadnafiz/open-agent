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

  init(_ raw: [String: Any]) {
    url = (raw["url"] as? String) ?? ""
    title = (raw["title"] as? String) ?? ""
    text = (raw["text"] as? String) ?? ""
    pageKey = (raw["page_key"] as? String) ?? ""
    let f = (raw["funnel"] as? [String: Any]) ?? [:]
    nodeCount = (f["all"] as? Double).map { Int($0) } ?? 0
    readyState = (f["ready"] as? String) ?? "complete"
    funnel =
      "all=\((f["all"] as? Double).map { Int($0) } ?? -1) "
      + "a=\((f["anchors"] as? Double).map { Int($0) } ?? -1) "
      + "btn=\((f["buttons"] as? Double).map { Int($0) } ?? -1) "
      + "raw=\((f["raw"] as? Double).map { Int($0) } ?? -1) "
      + "ready=\((f["ready"] as? String) ?? "?")"
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

    return snapshot.actions.map { action in
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
        // An occluded control is in the viewport and cannot be clicked: a modal
        // or a cookie banner is over it. Reported as out-of-viewport so the
        // deterministic filter drops it, rather than offering a candidate that
        // would silently click the overlay instead.
        inViewport: !action.occluded,
        bounds: action.bounds
      )
    }
  }

  public func readiness() async -> String {
    // **A document that says it is still loading is not settled, however still
    // it looks.** Instagram's inbox parks at ~507 nodes with `readyState:
    // loading` for seconds — stable, and nowhere near finished. Reporting the
    // state rather than a count lets the caller refuse to settle on it.
    guard let latest else { return "" }
    return latest.readyState == "complete" ? "\(latest.nodeCount)" : "loading"
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
