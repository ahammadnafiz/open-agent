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
    inViewport: Bool,
    bounds: CGRect,
    visionLabel: String? = nil
  ) {
    self.ref = ref
    self.role = role
    self.label = label
    self.enabled = enabled
    self.inViewport = inViewport
    self.bounds = bounds
    self.visionLabel = visionLabel
  }

  /// What `Enter` would activate if this element were focused. DOM only.
  public var submitLabel: String? { ref.submitLabel }

  /// A captured target nothing could name — `Constants.Safety.confirmUnnamedCaptured`.
  public var isCapturedWithNoLabel: Bool { ref.isCapturedWithNoLabel }
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
}

extension ElementSource {
  /// A compact textual rendering for the Jev `state`. **Not** the same as
  /// `observe()` — this is what lands in `screen_now`, and Jev's documented
  /// failure mode is that accuracy falls as `state` grows with irrelevant
  /// content. Filter before describing; never send a raw tree.
  public func describe(_ elements: [Element]) -> String {
    elements
      .map { "<\($0.role)> \($0.label)\($0.enabled ? "" : " (disabled)")" }
      .joined(separator: "\n")
  }
}
