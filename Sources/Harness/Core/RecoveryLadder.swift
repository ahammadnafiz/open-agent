import Foundation

/// What to do about a step that acted and did not progress.
///
/// Each rung is attempted at most once per step index:
///
/// ```
///   rung 0   retry the same action          clicks genuinely miss
///   rung 1   escalate this step to vision   the element list was insufficient
///   rung 2   replan from the current screen the route was wrong
///   rung 3   stop, surface state, ask
/// ```
///
/// **Rung 0 is skipped when the screen moved.** Jev distinguishes two failures
/// that the rung order alone conflates, and retrying the second is guaranteed
/// waste:
///
/// | `progressed` | `unchanged` | What happened | Rung |
/// |---|---|---|---|
/// | low | **high** | the action did nothing — a click missed | 0, retry |
/// | low | **low** | the screen moved, just not toward the goal | **straight to 2** |
///
/// The second row is what "the screen is new" looks like from inside the loop:
/// an unexpected dialog, the wrong account, a redirect. Retrying reproduces it.
/// The fixtures separate cleanly — 0.84/0.91 on genuine no-ops against 0.02–0.06
/// otherwise — so the branch is cheap and well supported.
public struct RecoveryLadder: Sendable {
  private var rungByStep: [Int: Int] = [:]

  public init() {}

  public mutating func next(
    for stepIndex: Int,
    verdict: StepVerdict,
    budget: Budget
  ) -> Recovery {
    var rung = (rungByStep[stepIndex] ?? -1) + 1

    // The screen changed and did not help. Retrying reproduces it exactly.
    if rung == 0, verdict.unchanged < Constants.Jev.unchanged {
      rung = 2
    }
    rungByStep[stepIndex] = rung

    // Budget exhaustion short-circuits a rung rather than failing the task
    // outright: a task that has spent its escalations can still replan, and
    // one that has spent its replans still surfaces cleanly rather than
    // being killed mid-action.
    // `retriesPerStep` is the number of rung-0 retries, and it is read here
    // rather than assumed. A constant in the file humans review before a release
    // that nothing reads is worse than no constant: editing it changes nothing,
    // which is exactly the failure the "no magic numbers" rule exists to stop.
    let retryRungs = Constants.Recovery.retriesPerStep
    if rung < retryRungs { return .retry }

    switch rung - retryRungs {
    case 0: return budget.canEscalate ? .escalate : (budget.canReplan ? .replan : .surface)
    case 1: return budget.canReplan ? .replan : .surface
    default: return .surface
    }
  }

  /// Rung already reached for a step index, for the log. `-1` means untouched.
  public func rung(for stepIndex: Int) -> Int { rungByStep[stepIndex] ?? -1 }
}
