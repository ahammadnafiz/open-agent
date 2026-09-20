import CoreGraphics
import Foundation
import Testing

@testable import Harness

@Suite("CandidateFilter")
struct CandidateFilterTests {

  static func element(
    label: String = "Post",
    role: String = "AXButton",
    enabled: Bool = true,
    inViewport: Bool = true,
    bounds: CGRect = CGRect(x: 0, y: 0, width: 40, height: 20)
  ) -> Element {
    Element(
      ref: .ax(path: [0], role: role, label: label),
      role: role, label: label,
      enabled: enabled, inViewport: inViewport, bounds: bounds
    )
  }

  @Test("an ordinary element survives")
  func ordinarySurvives() {
    #expect(CandidateFilter.isCandidate(Self.element()))
  }

  /// **Disabled controls are kept.** `docs/harness.md` §3.3 does not list
  /// `enabled` among the filter's conditions, and `docs/jev-questions.md` §2.1's
  /// own worked state example reads `<button> Post (disabled)` — Jev is meant to
  /// see that the control exists and is currently unavailable. That is often the
  /// difference between "the target is missing" and "the form is not filled in
  /// yet". Filtering them out also made `describe()`'s `(disabled)` branch
  /// unreachable, which is how this was caught.
  @Test("a disabled element is kept, and described as disabled")
  func disabledIsKept() {
    #expect(CandidateFilter.isCandidate(Self.element(enabled: false)))
    let set = CandidateSet(elements: [Self.element(label: "Post", enabled: false)])
    #expect(set.describe() == "<AXButton> Post (disabled)")
  }

  /// Addressable: the source must have given it a role. The AX walk already
  /// keeps only elements carrying at least one action, so an empty role is the
  /// one unaddressable case that reaches the filter.
  @Test("an element with no role is dropped")
  func rolelessDropped() {
    #expect(!CandidateFilter.isCandidate(Self.element(role: "")))
  }

  @Test("an offscreen element is dropped")
  func offscreenDropped() {
    #expect(!CandidateFilter.isCandidate(Self.element(inViewport: false)))
  }

  @Test(
    "a zero-size element is dropped",
    arguments: [
      CGRect(x: 0, y: 0, width: 0, height: 20),
      CGRect(x: 0, y: 0, width: 40, height: 0),
      CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
      .zero,
    ])
  func zeroSizeDropped(bounds: CGRect) {
    #expect(!CandidateFilter.isCandidate(Self.element(bounds: bounds)))
  }

  @Test("an unlabelled element is dropped", arguments: ["", "   ", "\n\t "])
  func unlabelledDropped(label: String) {
    #expect(!CandidateFilter.isCandidate(Self.element(label: label)))
  }

  // MARK: - SPEC.md S7 — the ≤255 invariant

  /// **Truncation would remove the correct answer without anyone noticing.**
  /// The step escalates to vision instead, which is the whole reason this
  /// throws rather than taking a prefix.
  @Test("more than 255 survivors throws rather than truncating")
  func tooManyThrows() {
    let elements = (0..<300).map { Self.element(label: "Item \($0)") }
    #expect(throws: CandidateError.tooManyCandidates(count: 300)) {
      _ = try CandidateFilter.reduce(elements)
    }
  }

  @Test("exactly 255 survivors is allowed")
  func exactly255() throws {
    let elements = (0..<255).map { Self.element(label: "Item \($0)") }
    let set = try CandidateFilter.reduce(elements)
    #expect(set.count == Constants.Jev.maxCandidates)
  }

  /// The ceiling applies to *survivors*, not to input. A page with 900
  /// actionable nodes routinely filters to well under the limit — measured
  /// 913 → 42 on Wikipedia, 227 → 127 on Hacker News.
  @Test("the ceiling counts survivors, not input")
  func ceilingCountsSurvivors() throws {
    let visible = (0..<100).map { Self.element(label: "Visible \($0)") }
    let hidden = (0..<900).map { Self.element(label: "Hidden \($0)", inViewport: false) }
    let set = try CandidateFilter.reduce(visible + hidden)
    #expect(set.count == 100)
  }

  // MARK: - Candidate ids

  /// `e`-prefixed, deliberately. Tier-4 mark indices and Jev score levels are
  /// both small integers; bare integer candidate ids would put three
  /// namespaces in one integer space.
  @Test("ids are e-prefixed and index-stable")
  func idsAreEPrefixed() throws {
    let set = try CandidateFilter.reduce([
      Self.element(label: "Post"), Self.element(label: "Home"),
    ])
    #expect(set.criteria["e0"] == "Post")
    #expect(set.criteria["e1"] == "Home")
    #expect(set.element(forID: "e1")?.label == "Home")
  }

  /// The id comes from a model response. A model that returns an out-of-range
  /// id must produce a handled escalation, not a trap.
  @Test("a malformed or out-of-range id resolves to nil", arguments: ["e99", "0", "", "ex", "e-1"])
  func malformedIDIsNil(id: String) throws {
    let set = try CandidateFilter.reduce([Self.element()])
    #expect(set.element(forID: id) == nil)
  }

  @Test("an empty screen produces an empty set rather than throwing")
  func emptyIsNotAnError() throws {
    let set = try CandidateFilter.reduce([])
    #expect(set.isEmpty)
    #expect(set.criteria.isEmpty)
  }

  @Test("describe renders role and label, and marks disabled")
  func describeRendering() {
    let set = CandidateSet(elements: [
      Self.element(label: "Post"),
      Self.element(label: "Draft", enabled: false),
    ])
    #expect(set.describe() == "<AXButton> Post\n<AXButton> Draft (disabled)")
  }
}
