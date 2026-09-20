import CoreGraphics
import Foundation

/// What the agent can do. Closed set, deliberately.
///
/// Additions require a reversibility decision and a denylist review — see
/// SPEC.md § Boundaries. `kind` is what the deterministic safety layer gates on,
/// which is the entire reason this is an enum and not a string.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
  // Reversible
  case openApp, navigate, click, type, pressKey, scroll, focus, select, read, wait
  // Irreversible by default — always confirmed, never auto-executed
  case publish, send, delete, purchase

  /// The planner-independent half of `Irreversibility.classify`.
  ///
  /// Mirrored in `Constants.Safety.irreversibleKinds` so the list is visible in
  /// the file humans review. This enum is the source of truth; `SafetyTests`
  /// asserts the two never drift.
  public var isIrreversibleByDefault: Bool {
    switch self {
    case .publish, .send, .delete, .purchase: true
    default: false
    }
  }
}

/// Keys `pressKey` may send. Closed for the same reason `ActionKind` is —
/// see ADR 0008. Arrow and editing keys are deliberately absent: an
/// autocomplete suggestion is a clickable element tiers 1–2 already resolve.
///
/// `enter` is the only key with an effect the denylist must reason about, and
/// it is classified against the focused element's *implicit submission target*,
/// not the field itself. A newline smuggled into `type`'s payload is not an
/// acceptable substitute: the confirmation shows the payload verbatim and a
/// trailing newline renders as nothing.
public enum Key: String, Codable, Sendable, CaseIterable {
  case enter, tab, escape
}

/// Where a `.captured` bounding box came from.
///
/// Load-bearing for execution, not decoration: `CapturedExecutor` refuses
/// `.ocrLine` outright because a merged OCR line spans several controls and its
/// centre lands on an arbitrary one of them — ADR 0007.
public enum Provenance: String, Codable, Sendable, CaseIterable {
  /// Vision `RecognizeTextRequest` — may span several controls. Never executed.
  case ocrLine
  /// Tier 3b detector — one control, no label.
  case detectorBox
  /// Tier 4 resolved a numbered mark to this box.
  case visionMark
}

/// Identity of a UI element. An identity is never a coordinate — see ADR 0001.
///
/// A raw coordinate cannot be risk-gated: nobody can tell whether clicking
/// (847,203) publishes a post or scrolls a list. Every case below carries enough
/// identity to be named in a confirmation dialog, matched by the denylist, and
/// written to a log a human can read months later.
///
/// `.captured` is the one case whose *actuation* is a point, computed inside the
/// executor from `bbox` at act time — see ADR 0007. The point is never part of
/// the ref, never what a model emits, and never what the log records as the
/// identity.
public enum ElementRef: Codable, Sendable, Hashable {
  /// Web. `handle` is a BiDi `script.NodeRemoteValue` sharedId; `selector` is a
  /// human-readable fallback used for logging and re-resolution after reload.
  case dom(handle: String, selector: String, label: String, submitLabel: String)

  /// Native. `path` is the index chain from the window root, which is stable
  /// only within one observation — always re-observe before acting.
  case ax(path: [Int], role: String, label: String)

  /// Tier 3/4. No element tree exists for this target. `label` may be empty,
  /// in which case `classify` returns `.irreversible` unconditionally.
  case captured(bbox: CGRect, label: String, provenance: Provenance)

  /// The name a human sees in a confirmation and the denylist matches on.
  public var label: String {
    switch self {
    case .dom(_, _, let label, _): label
    case .ax(_, _, let label): label
    case .captured(_, let label, _): label
    }
  }

  /// What `Enter` would actually activate. Only the DOM can compute this;
  /// a native text field carries no hint that its window sends on return.
  /// See ADR 0008 and Open Question Q8.
  public var submitLabel: String? {
    switch self {
    case .dom(_, _, _, let submitLabel): submitLabel.isEmpty ? nil : submitLabel
    case .ax, .captured: nil
    }
  }

  /// A captured target nothing in the system could name. Rare, and the right
  /// way to be wrong — `Constants.Safety.confirmUnnamedCaptured`.
  public var isCapturedWithNoLabel: Bool {
    guard case .captured(_, let label, _) = self else { return false }
    return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Which executor is total over this ref. See `Executor.for(_:)`.
  public var sourceKind: SourceKind {
    switch self {
    case .dom: .bidi
    case .ax: .ax
    case .captured: .captured
    }
  }
}

/// One thing the agent does, resolved against a live screen.
public struct Action: Codable, Sendable, Equatable {
  public let kind: ActionKind
  /// `nil` only for `openApp`, `navigate` and `wait`.
  public let target: ElementRef?
  /// Text to type, a url, an app name, or a `Key` raw value.
  public let payload: String?
  /// One line, for the log and the confirmation.
  public let rationale: String

  public init(kind: ActionKind, target: ElementRef?, payload: String?, rationale: String) {
    self.kind = kind
    self.target = target
    self.payload = payload
    self.rationale = rationale
  }

  /// The `Key` this action sends, or `nil` if it is not a keystroke.
  ///
  /// Parsed rather than stored so `payload` stays one field. An unparseable
  /// payload on `.pressKey` returns `nil`, and `Irreversibility.classify`
  /// treats that as "not a gated key" — safe, because an unknown key never
  /// reaches the executor either.
  public var key: Key? {
    guard kind == .pressKey, let payload else { return nil }
    return Key(rawValue: payload)
  }

  /// Kinds that name no on-screen element. `target` is `nil` for these, so the
  /// loop must not send them through selection — there is nothing to select.
  public var needsTarget: Bool {
    switch kind {
    case .openApp, .navigate, .wait: false
    default: true
    }
  }

  /// A one-line summary for `recent_history` and the step log.
  public var summary: String {
    let name = target?.label ?? payload ?? ""
    return name.isEmpty ? kind.rawValue : "\(kind.rawValue) \(name)"
  }
}
