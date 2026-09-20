import Foundation

/// Which ceiling stopped the task.
public enum BudgetCeiling: String, Sendable, Codable, CaseIterable {
  case steps, machineTime, escalations, replans, dollars
}

/// Hard ceilings. Every one of these has stopped a runaway in testing.
///
/// None is advisory. Hitting one stops the task cleanly, shows what was done,
/// and asks the user.
public struct Budget: Sendable, Equatable, Codable {
  public private(set) var stepsRemaining: Int
  public private(set) var machineTimeRemaining: Duration
  public private(set) var escalationsRemaining: Int
  public private(set) var replansRemaining: Int
  public private(set) var dollarsRemaining: Double

  public init(
    steps: Int = Constants.Budget.maxSteps,
    machineTime: Duration = Constants.Budget.maxMachineTime,
    escalations: Int = Constants.Budget.maxEscalations,
    replans: Int = Constants.Budget.maxReplans,
    dollars: Double = Constants.Budget.maxDollars
  ) {
    stepsRemaining = steps
    machineTimeRemaining = machineTime
    escalationsRemaining = escalations
    replansRemaining = replans
    dollarsRemaining = dollars
  }

  public mutating func chargeStep() { stepsRemaining -= 1 }

  /// **Machine time only.** Time spent awaiting human confirmation is NEVER
  /// charged — a task must not die because the user read carefully.
  /// SPEC.md § Boundaries: "Count human confirmation time against the task's
  /// wall-clock budget" is in the never-do set.
  public mutating func chargeMachineTime(_ d: Duration) {
    machineTimeRemaining -= d
  }

  public mutating func chargeEscalation() { escalationsRemaining -= 1 }
  public mutating func chargeReplan() { replansRemaining -= 1 }
  public mutating func chargeDollars(_ d: Double) { dollarsRemaining -= d }

  /// The first ceiling that has been crossed, or `nil` while all hold.
  ///
  /// Order is stable so the reported cause is deterministic when two ceilings
  /// are crossed by the same step.
  public func exhausted() -> BudgetCeiling? {
    if stepsRemaining <= 0 { return .steps }
    if machineTimeRemaining <= .zero { return .machineTime }
    if dollarsRemaining <= 0 { return .dollars }
    // Escalations and replans go negative only if something charged them
    // without checking `canEscalate` / `canReplan` first. They are ceilings in
    // SPEC.md § S4 exactly like the other three, so they are reported here
    // rather than silently overrun.
    if escalationsRemaining < 0 { return .escalations }
    if replansRemaining < 0 { return .replans }
    return nil
  }

  /// Escalations and replans do not end a task when they run out — the
  /// recovery ladder short-circuits that rung instead. A task that has spent
  /// its escalations can still replan, and one that has spent its replans
  /// still surfaces cleanly rather than being killed mid-action.
  public var canEscalate: Bool { escalationsRemaining > 0 }
  public var canReplan: Bool { replansRemaining > 0 }
}
