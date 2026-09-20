import Foundation

/// What the executor reports. **This is not verification.**
///
/// A click can be dispatched perfectly and change nothing; only the next step's
/// Jev batch knows whether the task moved. The executor reports *mechanics*;
/// Jev reports *progress*. Conflating the two is the failure this architecture
/// exists to prevent — `docs/harness.md` §7.1.
public struct ExecutionResult: Sendable, Codable, Equatable {
  /// The call itself succeeded. Says nothing about whether the task advanced.
  public let dispatched: Bool
  /// Which mechanism acted.
  public let via: SourceKind
  /// Hash of the screen frame the target's bounds were measured in.
  /// Required for `.captured` — without it the step is unreplayable, ADR 0007.
  public let frameHash: String?

  public init(dispatched: Bool, via: SourceKind, frameHash: String? = nil) {
    self.dispatched = dispatched
    self.via = via
    self.frameHash = frameHash
  }
}

/// What one step cost.
public struct Cost: Sendable, Codable, Equatable {
  public let dollars: Double
  public let inputTokens: Int
  public let outputTokens: Int

  public init(dollars: Double, inputTokens: Int, outputTokens: Int) {
    self.dollars = dollars
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }

  public init(_ usage: Usage) {
    self.init(
      dollars: usage.dollars,
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens
    )
  }

  public static let zero = Cost(dollars: 0, inputTokens: 0, outputTokens: 0)
}

/// The verdict that selected a step, flattened for the log.
///
/// SPEC.md § Boundaries requires every step to be logged *with its verdict*.
/// The full `StepVerdict` carries a `ChoiceAnswer` whose probability map is
/// unbounded in size, so the log keeps the five numbers a human reading it
/// months later would actually want.
public struct VerdictSummary: Sendable, Codable, Equatable {
  public let progressed: Double
  public let unchanged: Double
  public let blocked: Double
  public let taskDone: Double
  public let riskMax: Double
  public let selectionConfidence: Double?
  public let selectionMargin: Double?

  public init(_ verdict: StepVerdict) {
    progressed = verdict.progressed
    unchanged = verdict.unchanged
    blocked = verdict.blocked
    taskDone = verdict.taskDone
    riskMax = verdict.riskMax
    selectionConfidence = verdict.target?.confidence
    selectionMargin = verdict.target?.margin
  }
}

/// One completed iteration. Append-only; this is the audit log.
public struct Step: Sendable, Codable {
  public let index: Int
  public let action: Action
  public let result: ExecutionResult
  public let source: SourceKind
  public let usedVision: Bool
  public let cost: Cost
  public let elapsedMilliseconds: Int
  /// Verification of THIS step arrives in the NEXT iteration's Jev call, so
  /// this is the verdict that *selected* the action, not one that judged it.
  public let modelVersion: String
  public let requestID: String?
  /// Whether a human approved this step at the sheet.
  public let confirmed: Bool
  /// The verdict that selected this action. Verification of *this* step arrives
  /// in the next iteration's batch, so these are the numbers that chose it.
  public let verdict: VerdictSummary

  public init(
    index: Int, action: Action, result: ExecutionResult, source: SourceKind,
    usedVision: Bool, cost: Cost, elapsedMilliseconds: Int,
    modelVersion: String, requestID: String?, confirmed: Bool, verdict: VerdictSummary
  ) {
    self.index = index
    self.action = action
    self.result = result
    self.source = source
    self.usedVision = usedVision
    self.cost = cost
    self.elapsedMilliseconds = elapsedMilliseconds
    self.modelVersion = modelVersion
    self.requestID = requestID
    self.confirmed = confirmed
    self.verdict = verdict
  }
}

/// How a step resolved, after routing. Distinct cases get distinct treatment —
/// `docs/harness.md` §5.1.
public enum StepOutcome: Sendable, Equatable {
  /// Continue.
  case progressed
  /// Acted, no progress. Goes to the recovery ladder.
  case failed
  /// External obstacle. **Never retried** — retrying a login wall produces
  /// another login wall, and the agent has no credential to offer.
  case blocked(String)
  /// Repeating. Escalate once, then stop.
  case stuck
  /// Task complete.
  case done
}

/// What the ladder decided to do about a `failed` step.
public enum Recovery: Sendable, Equatable {
  case retry
  case escalate
  case replan
  case surface
}
