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
  // Reversible — pointer verbs that name one element, exactly as `click` does.
  //
  // Foley, Wallace & Chan (1984) decompose graphical interaction into select,
  // position, orient, path, quantify and text entry. The original set covered
  // *select* and *text entry*, and *quantify* only through the wheel. These
  // four finish the discrete half: a double press, a secondary press, a
  // pointer that arrives without pressing, and a value written straight to a
  // control that owns one.
  //
  // `setValue` is the interesting one — it makes *quantify* expressible
  // without a drag at all. A slider carries a settable `AXValue`, so "set zoom
  // to 150%" names an element and a number rather than a pixel to drag to,
  // which is the difference between an action that can be confirmed and one
  // that cannot.
  case doubleClick, rightClick, hover, setValue
  // Irreversible by default — always confirmed, never auto-executed
  case publish, send, delete, purchase
  /// Position and path, the two Foley tasks a coordinate would have been
  /// needed for — expressed as **two named elements** so ADR 0001 still holds.
  ///
  /// Irreversible by default, and alone among the pointer verbs in that. A
  /// click that lands wrong selects the wrong thing and the screen says so; a
  /// drag that lands wrong has already moved something, and where it came from
  /// is not written anywhere the agent can read back. Dropping a file onto
  /// Trash is a `delete` wearing a different verb, which is why the
  /// *destination* is an input to `Irreversibility.classify` and not decoration.
  case drag

  /// The planner-independent half of `Irreversibility.classify`.
  ///
  /// Mirrored in `Constants.Safety.irreversibleKinds` so the list is visible in
  /// the file humans review. This enum is the source of truth; `SafetyTests`
  /// asserts the two never drift.
  public var isIrreversibleByDefault: Bool {
    switch self {
    case .publish, .send, .delete, .purchase, .drag: true
    default: false
    }
  }
}

/// Keys `pressKey` may send. Closed for the same reason `ActionKind` is —
/// see ADR 0008.
///
/// `enter` is the only key with an effect the denylist must reason about, and
/// it is classified against the focused element's *implicit submission target*,
/// not the field itself. A newline smuggled into `type`'s payload is not an
/// acceptable substitute: the confirmation shows the payload verbatim and a
/// trailing newline renders as nothing.
///
/// **Arrow and editing keys were originally excluded** on the grounds that "an
/// autocomplete suggestion is a clickable element tiers 1–2 already resolve".
/// That is true of autocomplete and false of everything where an arrow is the
/// primary verb — a list the snapshot never collects, a canvas, a video
/// scrubber, a native table. The reasoning held for the case it was written
/// about and did not generalise, so the vocabulary is widened and the *gated*
/// set is not: an arrow activates nothing, and gating it would teach people the
/// confirmation sheet is noise.
///
/// **Clipboard keys are deliberately still absent.** `copy` and `paste` move
/// content the confirmation cannot display, and an action whose payload is
/// invisible breaks the one property every other action holds — that a human
/// sees exactly what is about to happen. `type` already covers text entry and
/// shows its payload verbatim.
public enum Key: String, Codable, Sendable, CaseIterable {
  case enter, tab, escape
  // Navigation
  case up, down, left, right, home, end, pageUp, pageDown
  // Editing
  case backspace, forwardDelete, space
  // Named combinations, not arbitrary modifier+key. A closed set of *meanings*
  // stays reviewable; `cmd+shift+<anything>` does not.
  case selectAll, undo
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
  /// `nil` only for `openApp`, `navigate` and `wait`. For `drag`, the thing
  /// being moved.
  public let target: ElementRef?
  /// Where a `drag` lets go. `nil` for every other kind.
  ///
  /// **A second `ElementRef`, never a point.** This is the whole reason `drag`
  /// can exist inside ADR 0001: a coordinate destination could not be shown in
  /// a confirmation, matched by the denylist, or read back out of a log — and
  /// "drag to (847,203)" is exactly the sentence the ADR was written to make
  /// impossible. A drop target that nothing can name is not a drag this agent
  /// performs.
  public let destination: ElementRef?
  /// Text to type, a url, an app name, a `Key` raw value, or the value
  /// `setValue` writes.
  public let payload: String?
  /// One line, for the log and the confirmation.
  public let rationale: String

  public init(
    kind: ActionKind, target: ElementRef?, destination: ElementRef? = nil,
    payload: String?, rationale: String
  ) {
    self.kind = kind
    self.target = target
    self.destination = destination
    self.payload = payload
    self.rationale = rationale
  }

  /// Kinds that name a second element. Only `drag` does.
  ///
  /// Required, not optional: an action that says "move this" without saying
  /// where can neither be executed nor confirmed, and a half-named drag is the
  /// shape a coordinate destination would sneak back in as.
  public static func needsDestination(_ kind: ActionKind) -> Bool { kind == .drag }

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
    // A drag names both ends. A confirmation reading "drag report.pdf" with no
    // destination is a confirmation of half the action — and the destination is
    // the half that decides whether it was destructive.
    if kind == .drag {
      let from = target?.label ?? "?"
      let to = destination?.label ?? "?"
      return "drag \(from) → \(to)"
    }
    // `setValue` carries its value in the payload, and the value is the point:
    // "setValue Zoom" says nothing a human can approve.
    if kind == .setValue, let value = payload, !value.isEmpty {
      return "setValue \(target?.label ?? "") = \(value)"
    }
    let name = target?.label ?? payload ?? ""
    return name.isEmpty ? kind.rawValue : "\(kind.rawValue) \(name)"
  }
}
