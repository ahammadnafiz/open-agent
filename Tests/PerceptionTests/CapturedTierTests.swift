import CoreGraphics
import Foundation
import Testing

@testable import Harness

/// Tier 3/4 — Open Question Q7.
///
/// The measurable part of Q7 is answered by `Probe captured-eval`. What is
/// pinned here is the safety property that makes tier 3 usable at all: its
/// output is never executed.
@Suite("Captured tier")
struct CapturedTierTests {

  static func captured(
    label: String, provenance: Provenance,
    bbox: CGRect = CGRect(x: 10, y: 10, width: 60, height: 20)
  ) -> Element {
    Element(
      ref: .captured(bbox: bbox, label: label, provenance: provenance),
      role: "", label: label, enabled: true, inViewport: true, bounds: bbox
    )
  }

  /// **The refusal is the safety property, not an unfinished edge.**
  ///
  /// A Vision line box spans several controls — measured `"Donate Create
  /// account Log in"` as one observation covering three links — and its centre
  /// lands on an arbitrary one of them. Splitting by gap was implemented and
  /// measured impossible: inter-link and intra-link spacing are identical at
  /// every resolution (2/2 px at DPR 1, 6/5 px at DPR 3). There is no threshold
  /// to find, so the only correct behaviour is to refuse.
  @Test("an ocrLine ref is refused by the executor")
  func ocrLineIsRefused() async {
    let executor = CapturedExecutor(pid: 0, appName: "test", frameHash: { "abc123" })
    let action = Action(
      kind: .click,
      target: Self.captured(label: "Donate Create account Log in", provenance: .ocrLine).ref,
      payload: nil, rationale: "test"
    )
    await #expect(throws: ExecutionError.ocrLineNotActionable) {
      _ = try await executor.execute(action)
    }
  }

  /// A bbox is meaningless without the frame it was measured in, so a step
  /// without the hash is unreplayable — ADR 0007 makes that a precondition.
  @Test("a captured action without a frame hash is refused")
  func missingFrameHashIsRefused() async {
    let executor = CapturedExecutor(pid: 0, appName: "test", frameHash: { nil })
    let action = Action(
      kind: .click,
      target: Self.captured(label: "Send", provenance: .visionMark).ref,
      payload: nil, rationale: "test"
    )
    await #expect(throws: (any Error).self) {
      _ = try await executor.execute(action)
    }
  }

  /// `confirmUnnamedCaptured` cannot fire on `.ocrLine`, which always carries
  /// text by construction. It is reachable only from `.detectorBox` (tier 3b,
  /// not built) and `.visionMark` (tier 4). Worth pinning, because it means the
  /// measured frequency Q7 asks about is structurally zero for tier 3 and the
  /// question only becomes answerable when 3b or 4 lands.
  @Test("an OCR line always carries a label, so the unnamed rule cannot fire on it")
  func ocrLineIsNeverUnnamed() {
    let element = Self.captured(label: "Some text", provenance: .ocrLine)
    #expect(element.isCapturedWithNoLabel == false)

    // The other two provenances can be nameless, and that is what the rule is for.
    let nameless = Self.captured(label: "", provenance: .detectorBox)
    #expect(nameless.isCapturedWithNoLabel)
    #expect(
      Irreversibility.classify(
        Action(kind: .click, target: nameless.ref, payload: nil, rationale: ""),
        target: nameless
      ) == .irreversible
    )
  }

  /// Pixels carry no role. No Apple framework returns one — all 34 Vision
  /// request types were benchmarked during design and none knows what a button
  /// is. Inventing a role here would make the denylist's role check fire on a
  /// guess.
  @Test("a captured element claims no role")
  func capturedHasNoRole() {
    #expect(Self.captured(label: "Send", provenance: .ocrLine).role.isEmpty)
  }

  /// Tier 3 output feeds tier 4's marks rather than being selected from, and
  /// the constant that says so must stay true until the 3b detector exists.
  @Test("tier 3 is not a selection tier")
  func tier3FeedsMarksOnly() {
    #expect(Constants.OCR.tier3FeedsMarksOnly)
  }

  /// MUST be 0. The Swift struct defaults it to 0.03125, which returns ZERO
  /// observations on a Retina screenshot — a silent total failure, not an
  /// error. Measured sweep at 2880x1800: 0.0 gave 86 observations, the default
  /// gave 0.
  @Test("the minimum text height fraction is zero")
  func minimumTextHeightIsZero() {
    #expect(Constants.OCR.minimumTextHeightFraction == 0.0)
  }
}
