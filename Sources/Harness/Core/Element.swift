import CoreGraphics
import Foundation

/// Which mechanism produced — and will act on — an element.
///
/// Two cases in the original design (`docs/harness.md` §3.2). `captured` was
/// added by ADR 0007, which made tiers 3–4 executable and therefore required a
/// third executor. `Executor.for(_:)` switches over this exhaustively; a ref the
/// harness can produce but not act on is the exact defect ADR 0007 closed.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
  /// Tier 1 — DOM via WebDriver BiDi. Dispatches to an element.
  case bidi
  /// Tier 2 — Accessibility tree. Dispatches to an element.
  case ax
  /// Tiers 3–4 — no element tree. Actuates with a synthesized event.
  case captured
}

/// One actionable thing on screen, as a source reported it.
public struct Element: Sendable, Hashable, Codable {
  public let ref: ElementRef
  /// `"button"`, `"link"`, `"textbox"`, `"AXButton"` — source-native, not normalised.
  public let role: String
  /// `aria-label ∨ innerText ∨ value ∨ placeholder ∨ title`, already trimmed.
  public let label: String
  public let enabled: Bool
  /// What the control currently *contains*, when that is not what it is
  /// *called*. Empty for everything that holds nothing.
  ///
  /// **Kept apart from `label` because they answer different questions.**
  /// `label` is identity — which control this is — and `AXPrimitives.label`
  /// deliberately prefers a placeholder over a value so that a field does not
  /// become a different element the moment someone types in it. That is the
  /// right rule for choosing a target and the wrong one for judging whether
  /// typing worked: the text went in, the label still read `Message`, and
  /// `screen_before` and `screen_now` were byte-identical across a step that
  /// had fully succeeded. Measured live on Finder's search field — after
  /// typing, `AXValue` reads `Bangla QR report` while the label precedence
  /// never reaches it.
  ///
  /// So identity stays in `label`, where selection reads it, and content lands
  /// here, where `described` renders it for verification.
  public let value: String
  /// Whether this element holds the keyboard.
  ///
  /// **A click into a text field changes nothing else.** No label moves, no
  /// control appears or disappears, and the only thing that is now true which
  /// was not true before is that keystrokes will land here. Without this the
  /// two screens compare equal, `progressed` came back 0.22–0.24 on a click
  /// that had worked perfectly, and the loop retried it — then scored
  /// `looping` 0.91 against its own retry. A plain click-then-type plan could
  /// not get past its first step.
  ///
  /// Both tiers already knew the answer: the DOM snapshot reports `focused`
  /// and `AXSource` can read `AXFocusedUIElement`. Neither reached the state.
  public let focused: Bool
  public let inViewport: Bool
  /// Read by `CandidateFilter`, by vision when rendering marks, and by the
  /// overlay when drawing the target ring. **It never reaches an `Action`, a
  /// plan, a Jev `state`, or a step log's identity field** — that is the line
  /// ADR 0001 draws, and it is about identity, not about whether any code may
  /// ever look at a rectangle.
  public let bounds: CGRect
  /// What tier 4 called this element, when tier 4 named it.
  ///
  /// Read off pixels, so attacker-influenced — and admissible anyway, because
  /// `Irreversibility.classify` can only ever *raise* on it. See ADR 0007 §3.
  public let visionLabel: String?

  public init(
    ref: ElementRef,
    role: String,
    label: String,
    enabled: Bool,
    value: String = "",
    focused: Bool = false,
    inViewport: Bool,
    bounds: CGRect,
    visionLabel: String? = nil
  ) {
    self.ref = ref
    self.role = role
    self.label = label
    self.enabled = enabled
    self.value = value
    self.focused = focused
    self.inViewport = inViewport
    self.bounds = bounds
    self.visionLabel = visionLabel
  }

  /// What `Enter` would activate if this element were focused. DOM only.
  public var submitLabel: String? { ref.submitLabel }

  /// **Tolerant of fixtures recorded before a field existed.**
  ///
  /// `Probe capture-fixtures` commits real captures from live pages, and S7
  /// asserts against them. Those files are evidence, not test scaffolding —
  /// re-recording them to add a key would throw away the provenance that makes
  /// them worth having. A capture taken before `value` and `focused` existed
  /// has no opinion about either, and empty-and-unfocused is exactly that.
  ///
  /// Only `init(from:)` is hand-written; `encode(to:)` stays synthesised, so
  /// anything written from here on carries both keys.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ref = try container.decode(ElementRef.self, forKey: .ref)
    role = try container.decode(String.self, forKey: .role)
    label = try container.decode(String.self, forKey: .label)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    inViewport = try container.decode(Bool.self, forKey: .inViewport)
    bounds = try container.decode(CGRect.self, forKey: .bounds)
    visionLabel = try container.decodeIfPresent(String.self, forKey: .visionLabel)
  }

  /// A captured target nothing could name — `Constants.Safety.confirmUnnamedCaptured`.
  public var isCapturedWithNoLabel: Bool { ref.isCapturedWithNoLabel }

  /// This element as one line of a Jev `state`.
  ///
  /// **The single rendering.** It was written out twice — once here on
  /// `ElementSource` and once on `CandidateSet` — and only the second was ever
  /// called. Two copies of the format that decides what the judge can see is
  /// how one of them silently stops carrying a field.
  ///
  /// The value is suppressed when it merely repeats the label, which is the
  /// common case for a file row or a DOM input whose accessible name *is* its
  /// contents. Rendering `<AXRow> report.pdf = "report.pdf"` spends tokens to
  /// say nothing, and Jev's documented failure mode is accuracy falling as the
  /// state grows with irrelevant content.
  public var described: String {
    var line = "<\(role)> \(label)"
    if focused { line += " (focused)" }
    if !enabled { line += " (disabled)" }
    if !value.isEmpty, value != label { line += " = \"\(value)\"" }
    return line
  }
}

/// Everything actionable a source can see, plus the rendering the Jev `state` gets.
public protocol ElementSource: Sendable {
  /// Everything actionable the source can see, unfiltered.
  func observe() async throws -> [Element]
  var kind: SourceKind { get }
  /// The candidate that currently holds keyboard focus, when the source can say.
  ///
  /// A requirement rather than a cast at the call site: both tiers can answer
  /// it, and the loop asking `source as? AXSource` is what left the browser
  /// tier guessing where `Enter` should go.
  func focused(among elements: [Element]) async -> Element?

  /// How finished this screen looks — see the `readiness` notes below.
  ///
  /// **A requirement, not an extension member.** It lived only in an extension,
  /// and the loop holds its source as `any ElementSource` — so every call from
  /// the loop dispatched statically to the default `""`, and the browser tier's
  /// answer was never heard. `readyState: loading`, the busy count, and the
  /// node count were all being computed, reported, and thrown away.
  func readiness() async -> String

  /// Whether asking is worth an observation.
  ///
  /// A source that cannot tell a half-built screen from a finished one should
  /// not be observed twice to find that out — the accessibility tier's walk is
  /// measured in hundreds of milliseconds, and it would be paid every step to
  /// be told nothing.
  var reportsReadiness: Bool { get }

  /// What the screen *says*, as opposed to what can be pressed on it.
  ///
  /// **A requirement, not an extension member** — for exactly the reason
  /// `readiness()` is one. The loop holds its source as `any ElementSource`,
  /// so a method that exists only in an extension dispatches statically to the
  /// default and the browser tier's answer is never heard. This codebase has
  /// already written that bug twice.
  ///
  /// Candidates answer "what can I do here". They cannot answer "what does it
  /// say" — a link contributes its own text and nothing else does, so a list
  /// of issue titles arrives and the issues themselves do not. The page text
  /// was being collected by the snapshot and dropped on the floor; this is the
  /// wire it was missing. Tiers with no prose to offer return empty.
  func pageText() async -> String
}

extension ElementSource {
  /// Sources with no notion of focus say so, rather than being asked to lie.
  public func focused(among elements: [Element]) async -> Element? { nil }
}

/// How finished a screen looks, beyond the elements it is offering.
///
/// **A page can be stable and not ready.** Instagram's inbox reports
/// `readyState: complete` with its navigation rail rendered and its
/// conversations absent — twelve elements, unchanged between polls, for
/// seconds. Waiting for the element list to stop moving therefore stopped too
/// early, on a shell.
///
/// The DOM node count keeps climbing while a single-page application builds
/// itself, so it separates "nothing more is coming" from "nothing has arrived
/// yet". Sources that have no such signal return an empty string and settle on
/// their element list alone, exactly as before.
extension ElementSource {
  public func readiness() async -> String { "" }
  public var reportsReadiness: Bool { false }
  /// Sources that read a tree of controls, not a document, have no prose.
  public func pageText() async -> String { "" }
}

extension ElementSource {
  /// A compact textual rendering for the Jev `state`. **Not** the same as
  /// `observe()` — this is what lands in `screen_now`, and Jev's documented
  /// failure mode is that accuracy falls as `state` grows with irrelevant
  /// content. Filter before describing; never send a raw tree.
  public func describe(_ elements: [Element]) -> String {
    elements.map(\.described).joined(separator: "\n")
  }
}
