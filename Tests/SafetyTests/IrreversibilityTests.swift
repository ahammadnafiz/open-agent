import CoreGraphics
import Foundation
import Testing

@testable import Harness

/// SPEC.md § S3 — "No unconfirmed irreversible action is reachable."
///
/// These assert by **enumeration**, not by sampling. `Safety/` is the only code
/// in this system where a bug is unrecoverable, so the coverage expectation is
/// every branch rather than a percentage — SPEC.md § Testing Strategy.
@Suite("Irreversibility is upgrade-only")
struct IrreversibilityTests {

  // MARK: - Helpers

  /// An element with no property that could trip any denylist input.
  /// Every test that wants a *neutral* target uses this, so a test that goes
  /// irreversible does so for exactly the reason it names.
  static func inertElement(
    label: String = "Preferences",
    role: String = "AXButton",
    visionLabel: String? = nil,
    submitLabel: String = ""
  ) -> Element {
    Element(
      ref: .dom(handle: "h1", selector: "#p", label: label, submitLabel: submitLabel),
      role: role,
      label: label,
      enabled: true,
      inViewport: true,
      bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
      visionLabel: visionLabel
    )
  }

  static func action(_ kind: ActionKind, payload: String? = nil) -> Action {
    Action(kind: kind, target: nil, payload: payload, rationale: "test")
  }

  /// Labels drawn from every alternation in `Constants.Safety.labelDenylist`.
  /// If a term is added to the pattern and not here, `denylistTermsAreCovered`
  /// fails — the pattern and this list cannot drift apart silently.
  static let denylistLabels = [
    "Post", "Tweet", "Publish", "Share",
    "Send", "Reply", "Submit", "Confirm",
    "Delete", "Remove", "Discard", "Destroy", "Erase", "Wipe",
    "Buy", "Purchase", "Pay", "Checkout", "Order", "Subscribe",
    "Deactivate", "Close account", "Transfer", "Withdraw",
  ]

  // MARK: - The core invariant

  /// **The one thing that must not rot.** No component may return
  /// `.reversible` for an action another component called `.irreversible`.
  ///
  /// Exhaustive over `ActionKind` × denylist label. 19 × 24 = 456 cases.
  @Test("every ActionKind with every denylist label classifies irreversible")
  func everyKindWithEveryDenylistLabel() {
    for kind in ActionKind.allCases {
      for label in Self.denylistLabels {
        let target = Self.inertElement(label: label)
        let result = Irreversibility.classify(Self.action(kind), target: target)
        #expect(
          result == .irreversible,
          "\(kind.rawValue) on label '\(label)' must be irreversible"
        )
      }
    }
  }

  /// The kind alone is sufficient, with no target at all.
  @Test("irreversible kinds classify irreversible with no target")
  func irreversibleKindsAlone() {
    for kind in ActionKind.allCases where kind.isIrreversibleByDefault {
      #expect(Irreversibility.classify(Self.action(kind), target: nil) == .irreversible)
    }
  }

  /// Nothing downgrades. Every *single* input, on its own, forces irreversible
  /// while all the others are inert.
  @Test("each input independently forces irreversible")
  func eachInputIsIndependentlySufficient() {
    let inert = Self.inertElement()

    // 1. kind
    #expect(Irreversibility.classify(Self.action(.send), target: inert) == .irreversible)

    // 2. planner declaration, on an otherwise fully reversible action
    #expect(
      Irreversibility.classify(Self.action(.click), target: inert, declaredByPlanner: true)
        == .irreversible
    )

    // 3. source label
    #expect(
      Irreversibility.classify(
        Self.action(.click), target: Self.inertElement(label: "Delete")
      ) == .irreversible
    )

    // 4. vision label — attacker-influenced, admissible because upgrade-only
    #expect(
      Irreversibility.classify(
        Self.action(.click), target: Self.inertElement(visionLabel: "the Post button")
      ) == .irreversible
    )

    // 5. submit label reached through pressKey(.enter)
    #expect(
      Irreversibility.classify(
        Self.action(.pressKey, payload: Key.enter.rawValue),
        target: Self.inertElement(submitLabel: "Send")
      ) == .irreversible
    )

    // 6. unnamed captured target
    let unnamed = Element(
      ref: .captured(
        bbox: .init(x: 1, y: 1, width: 2, height: 2), label: "", provenance: .visionMark),
      role: "", label: "", enabled: true, inViewport: true,
      bounds: .init(x: 1, y: 1, width: 2, height: 2)
    )
    #expect(Irreversibility.classify(Self.action(.click), target: unnamed) == .irreversible)
  }

  /// The baseline the tests above are measured against. If this ever returns
  /// `.irreversible`, every assertion above is vacuous.
  @Test("a fully inert action is reversible")
  func inertIsReversible() {
    #expect(
      Irreversibility.classify(Self.action(.click), target: Self.inertElement()) == .reversible)
    #expect(
      Irreversibility.classify(Self.action(.scroll), target: Self.inertElement()) == .reversible)
    #expect(Irreversibility.classify(Self.action(.read), target: nil) == .reversible)
  }

  // MARK: - Keystroke gating — ADR 0008

  /// `tab` moves focus and activates nothing; `escape` dismisses, which is
  /// reversible by construction. Only `enter` is routed through the denylist.
  @Test("only enter is gated, even against a denylisted submit target")
  func onlyEnterIsGated() {
    let submits = Self.inertElement(submitLabel: "Publish")
    for key in Key.allCases {
      let result = Irreversibility.classify(
        Self.action(.pressKey, payload: key.rawValue), target: submits
      )
      if key == .enter {
        #expect(result == .irreversible, "enter must be gated on a Publish submit target")
      } else {
        #expect(result == .reversible, "\(key.rawValue) must not be gated")
      }
    }
  }

  /// A newline smuggled into `type` must NOT be how a submission happens —
  /// ADR 0008. This documents the gap rather than hiding it: `type` carrying
  /// "\n" is classified on its label alone, which is exactly why `pressKey`
  /// exists as a separate kind.
  @Test("pressKey with an unparseable payload is not treated as a gated key")
  func unknownKeyPayloadIsNotGated() {
    let result = Irreversibility.classify(
      Self.action(.pressKey, payload: "f13"),
      target: Self.inertElement(submitLabel: "Send")
    )
    #expect(result == .reversible)
  }

  // MARK: - Confirmation

  @Test("confirmation is required for irreversible regardless of risk")
  func confirmationForIrreversible() {
    #expect(Irreversibility.requiresConfirmation(.irreversible, riskMax: 0.0))
  }

  /// The advisory gate decides whether to **ask**, never whether to **allow**.
  @Test("advisory risk at or above the threshold confirms a reversible action")
  func confirmationForRiskyReversible() {
    #expect(Irreversibility.requiresConfirmation(.reversible, riskMax: Constants.Jev.riskConfirm))
    #expect(
      !Irreversibility.requiresConfirmation(.reversible, riskMax: Constants.Jev.riskConfirm - 0.01))
  }

  /// A fork bomb scored 0.15 on the risk battery and a semantic reframing moved
  /// a destructive command from 0.98 to 0.42. Neither can reach the boundary,
  /// because the boundary does not read risk at all when the kind is irreversible.
  @Test("a suppressed risk score cannot waive an irreversible classification")
  func riskCannotWaiveIrreversible() {
    #expect(Irreversibility.requiresConfirmation(.irreversible, riskMax: 0.42))
    #expect(Irreversibility.requiresConfirmation(.irreversible, riskMax: 0.0))
  }
}
