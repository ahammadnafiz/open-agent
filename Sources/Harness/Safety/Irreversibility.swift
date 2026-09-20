import Foundation

/// Whether an action can be undone. `Comparable`, with `irreversible > reversible`,
/// so `max` is the aggregation and a downgrade is not expressible.
public enum Reversibility: Int, Comparable, Sendable, Codable, CaseIterable {
  case reversible = 0
  case irreversible = 1

  public static func < (lhs: Reversibility, rhs: Reversibility) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// `true` maps to the stricter value. Every input to `classify` is phrased so
  /// that `true` means *more* caution — never invert this.
  public static func from(_ flag: Bool) -> Reversibility {
    flag ? .irreversible : .reversible
  }
}

/// The deterministic safety gate. Runs after selection, before execution, on
/// every action. **No model verdict reaches it.**
///
/// ```
///   declared ──┐   kind default OR planner claim
///   bySource ──┤   the label the source gave this element
///   byVision ──┼── max() ──► effective        upgrade-only, ADR 0001
///   bySubmit ──┤   what Enter would activate
///   unnamed  ──┘   a captured target nothing could name
/// ```
///
/// The five inputs are independent; **all** of them must fail silently and
/// simultaneously for an unconfirmed irreversible action to occur.
///
/// Two of them accept model-derived and page-derived strings, and that is safe
/// precisely because every input is upgrade-only. An attacker who controls what
/// the vision model reads, or what a form's submit button says, can make the
/// agent ask the user **more** often — never less.
public enum Irreversibility {

  /// Classifies an action's reversibility. Can only ever escalate, never relax.
  ///
  /// - Parameters:
  ///   - action: carries `kind` (the planner-independent half) and, for
  ///     `pressKey`, which key.
  ///   - target: the resolved element, or `nil` for `openApp`/`navigate`/`wait`.
  ///   - declaredByPlanner: the host's own claim from `PlanStep`. One of five
  ///     inputs and never the only one, so a host that declares too little is
  ///     caught by the other four.
  public static func classify(
    _ action: Action,
    target: Element?,
    declaredByPlanner: Bool = false
  ) -> Reversibility {

    // 1. Declared. The kind's own default, OR the planner's claim for this
    //    step — one input, as `docs/host-contract.md` §3.2 counts them
    //    ("one of five inputs"). Both are assertions about intent made before
    //    the screen was seen, and both can only ever raise the result, so
    //    OR-ing them loses nothing and keeps the count honest.
    let declared = Reversibility.from(
      action.kind.isIrreversibleByDefault || declaredByPlanner
    )

    // 2. Whatever the source named this element. Empty for an unlabelled icon.
    let bySource = Reversibility.from(
      LabelDenylist.matches(target?.label) || LabelDenylist.matchesRole(target?.role)
    )

    // 3. What tier 4 called the element it selected. Read off pixels, so
    //    attacker-influenced — and admissible anyway, because it can only
    //    ever RAISE the classification. See ADR 0007 §3.
    let byVision = Reversibility.from(LabelDenylist.matches(target?.visionLabel))

    // 4. What `Enter` would actually activate. A text field does not carry
    //    the label of the button its form submits to — ADR 0008. Only gated
    //    keys are routed through the denylist: `tab` moves focus and
    //    activates nothing, `escape` dismisses, which is reversible by
    //    construction.
    let bySubmit: Reversibility = {
      guard let key = action.key,
        Constants.Safety.gatedKeys.contains(key.rawValue)
      else { return .reversible }
      return Reversibility.from(LabelDenylist.matches(target?.submitLabel))
    }()

    // 5. A captured target nothing could name. Rare, and the right way to be
    //    wrong: a target no component can describe cannot be denylisted at
    //    all, and acting on it unconfirmed is the one case with no mechanism
    //    behind it.
    let unnamed = Reversibility.from(
      Constants.Safety.confirmUnnamedCaptured && (target?.isCapturedWithNoLabel ?? false)
    )

    return max(declared, max(bySource, max(byVision, max(bySubmit, unnamed))))
  }

  /// Whether this action needs a human at the sheet before it runs.
  ///
  /// Two independent reasons, and they are not the same thing:
  ///   - `.irreversible` — deterministic, never waivable by any model result.
  ///   - advisory risk at or above `Constants.Jev.riskConfirm` — a *reversible*
  ///     action Jev flagged. This gate decides whether to **ask**, never
  ///     whether to **allow**.
  public static func requiresConfirmation(
    _ effective: Reversibility,
    riskMax: Double
  ) -> Bool {
    effective == .irreversible || riskMax >= Constants.Jev.riskConfirm
  }
}
