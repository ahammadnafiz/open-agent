import Foundation

/// A labelled case for `Probe battery-eval`.
///
/// One `StepContext` plus, for every question it exercises, which side of that
/// question's threshold the answer must land on. `docs/jev-questions.md` §7
/// requires at least four per question including one deliberately ambiguous
/// case — the ambiguous one is the point, because a question that only ever
/// sees easy inputs has never been tested at its threshold.
public struct BatteryFixture: Codable, Sendable {
  public let name: String
  /// Why this case exists, and where its expected values came from.
  public let provenance: String
  public let state: FixtureState
  /// `question id → expected side`. A question absent here is not scored.
  public let expect: [String: Side]

  public enum Side: String, Codable, Sendable {
    /// The answer must be **at or above** the question's threshold.
    case above
    /// The answer must be **below** it.
    case below
  }

  public struct FixtureState: Codable, Sendable {
    public let task: String
    public let planStep: PlanStepDTO
    public let lastAction: ActionDTO?
    public let screenBefore: String
    public let screenNow: String
    public let recentHistory: [String]
    public let candidates: [String: String]
    public let taskContext: String
    /// For `target` only: the candidate id that is correct.
    public let expectedTarget: String?

    private enum CodingKeys: String, CodingKey {
      case task
      case planStep = "plan_step"
      case lastAction = "last_action"
      case screenBefore = "screen_before"
      case screenNow = "screen_now"
      case recentHistory = "recent_history"
      case candidates
      case taskContext = "task_context"
      case expectedTarget = "expected_target"
    }

    public var context: StepContext {
      StepContext(
        task: task, planStep: planStep, lastAction: lastAction,
        screenBefore: screenBefore, screenNow: screenNow,
        recentHistory: recentHistory, candidates: candidates, taskContext: taskContext
      )
    }
  }

  /// The threshold a question is scored against. Kept here rather than in the
  /// fixture file so a threshold change is a code change, reviewed in one
  /// place, and cannot be silently re-tuned per fixture to make a suite pass.
  public static func threshold(for question: String) -> Double? {
    switch question {
    case Batteries.ID.progressed: Constants.Jev.progressed
    case Batteries.ID.unchanged: Constants.Jev.unchanged
    case Batteries.ID.blocked: Constants.Jev.blocked
    case Batteries.ID.taskDone: Constants.Jev.taskDone
    case Batteries.ID.looping: Constants.Jev.looping
    case Batteries.ID.wrongContext: Constants.Jev.wrongContext
    case Batteries.ID.sufficient: Constants.Jev.sufficient
    case Batteries.ID.riskDestructive, Batteries.ID.riskOutbound,
      Batteries.ID.riskCredential:
      Constants.Jev.riskConfirm
    default: nil
    }
  }

  /// Loads every fixture in a directory, sorted by name so a run is reproducible.
  public static func load(from directory: URL) throws -> [BatteryFixture] {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let decoder = JSONDecoder()
    return try files.map { try decoder.decode(BatteryFixture.self, from: try Data(contentsOf: $0)) }
  }
}
