import CoreGraphics
import Foundation

/// Deterministic reduction from everything a source can see to the option set
/// Jev chooses from.
///
/// **No model participates in deciding what is a candidate.** A model that
/// filters its own option set can hide the right answer from itself.
///
/// ```
///   keep an element iff
///       rendered        width ≥ 1 ∧ height ≥ 1
///     ∧ in viewport     the source marked it visible
///     ∧ labelled        non-empty label after trimming
///     ∧ addressable     carries a role the source considers actionable
/// ```
///
/// **Disabled controls are kept, deliberately.** An earlier version filtered
/// them out, which contradicted `docs/jev-questions.md` §2.1 — its own worked
/// state example reads `<button> Post (disabled)`. Jev needs to see that the
/// control exists and is currently unavailable; that is often the difference
/// between "the target is missing" and "the form is not filled in yet". The
/// `(disabled)` suffix in `describe()` is how it learns that, and filtering
/// these out made that branch unreachable.
///
/// Measured on real pages this lands far below the ceiling — worst observed is
/// 127 on a link-dense page, against a limit of 255. **No chunking or
/// pre-ranking stage is needed, and none should be added speculatively.**
public enum CandidateFilter {

  /// Applies the filter and assigns stable candidate ids.
  ///
  /// - Throws: `CandidateError.tooManyCandidates` when more than
  ///   `Constants.Jev.maxCandidates` survive. The step escalates to vision
  ///   rather than silently truncating — **truncation would remove the correct
  ///   answer without anyone noticing**, which is the worst available failure.
  public static func reduce(_ elements: [Element]) throws -> CandidateSet {
    let kept = elements.filter(isCandidate)

    guard kept.count <= Constants.Jev.maxCandidates else {
      throw CandidateError.tooManyCandidates(count: kept.count)
    }
    return CandidateSet(elements: kept)
  }

  /// One element's eligibility. Split out so the rule is testable in isolation
  /// and readable as the specification it is.
  public static func isCandidate(_ element: Element) -> Bool {
    guard element.inViewport else { return false }
    guard element.bounds.width >= 1, element.bounds.height >= 1 else { return false }
    guard !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    // Addressable. The AX walk already keeps only elements carrying at least one
    // action, and the DOM source applies the equivalent rule, so an empty role
    // is the one case that reaches here unaddressable.
    guard !element.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return true
  }
}

/// The filtered elements plus their opaque ids.
///
/// Ids are `e0`, `e1`, … — **not bare integers.** Tier-4 mark indices and Jev
/// score levels are both small integers, and three distinct integer namespaces
/// in one system is one bug waiting to be written. The prefix also makes a
/// candidate id greppable in a log.
///
/// The key is never sent as meaningful text: the vendor documents that question
/// keys are not used in inference, and the same discipline applies here. The
/// **label** carries the signal; the id is only how code finds the element again.
public struct CandidateSet: Sendable, Equatable {
  public let elements: [Element]

  public init(elements: [Element]) { self.elements = elements }

  public var isEmpty: Bool { elements.isEmpty }
  public var count: Int { elements.count }

  /// `id → label`, the Choice option set.
  public var criteria: [String: String] {
    Dictionary(
      uniqueKeysWithValues: elements.enumerated().map {
        (Self.id(for: $0.offset), $0.element.label)
      }
    )
  }

  public static func id(for index: Int) -> String { "e\(index)" }

  /// Resolves an id Jev returned back to the element it names.
  ///
  /// Returns `nil` rather than crashing on a malformed id: the value comes
  /// from a model response, and a model that returns `"e99"` for a 3-candidate
  /// set must produce a handled escalation, not a trap.
  public func element(forID id: String) -> Element? {
    guard id.hasPrefix("e"), let index = Int(id.dropFirst()),
      elements.indices.contains(index)
    else { return nil }
    return elements[index]
  }

  /// A compact rendering for the Jev `state`. Filtered, never raw.
  public func describe() -> String {
    elements
      .map { "<\($0.role)> \($0.label)\($0.enabled ? "" : " (disabled)")" }
      .joined(separator: "\n")
  }
}
