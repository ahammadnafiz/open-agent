import Foundation

// MARK: - Request

/// The Jev `state` for one step.
///
/// **Keep this minimal and resist growing it.** Jev's documentation is explicit
/// that accuracy falls as `state` grows with content unrelated to the decision —
/// they call it context rot. `screenBefore` and `screenNow` are the *filtered*
/// element lists, never raw DOM and never full page text. The filter is not an
/// optimisation; it is an accuracy measure.
public struct StepContext: Encodable, Sendable, Equatable {
  /// The user's original sentence.
  public let task: String
  public let planStep: PlanStepDTO
  /// `nil` on step 0.
  public let lastAction: ActionDTO?
  /// `describe()` from BEFORE the last action.
  public let screenBefore: String
  /// `describe()` from now.
  public let screenNow: String
  /// Last `Constants.Jev.historyWindow` action summaries.
  public let recentHistory: [String]
  /// `id → label`. The Choice option set. Keys are opaque; the label carries
  /// all the signal.
  public let candidates: [String: String]
  /// The specific *instance* the task names — an account, a mailbox, a
  /// document, a repository. Empty when the task names none.
  ///
  /// Exists for exactly one question, `wrong_context`, and nothing else reads
  /// it. Asking about a context the task never named invents one.
  public let taskContext: String

  public init(
    task: String, planStep: PlanStepDTO, lastAction: ActionDTO?,
    screenBefore: String, screenNow: String, recentHistory: [String],
    candidates: [String: String], taskContext: String = ""
  ) {
    self.task = task
    self.planStep = planStep
    self.lastAction = lastAction
    self.screenBefore = screenBefore
    self.screenNow = screenNow
    self.recentHistory = recentHistory
    self.candidates = candidates
    self.taskContext = taskContext
  }

  private enum CodingKeys: String, CodingKey {
    case task
    case planStep = "plan_step"
    case lastAction = "last_action"
    case screenBefore = "screen_before"
    case screenNow = "screen_now"
    case recentHistory = "recent_history"
    case candidates
    case taskContext = "task_context"
  }

  /// Whether `wrong_context` should be asked at all.
  public var namesAnInstance: Bool {
    !taskContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public struct PlanStepDTO: Codable, Sendable, Equatable {
  public let kind: String
  public let target: String
  public let payload: String?

  public init(kind: String, target: String, payload: String?) {
    self.kind = kind
    self.target = target
    self.payload = payload
  }

  public init(_ step: PlanStep) {
    self.init(kind: step.kind.rawValue, target: step.target, payload: step.payload)
  }
}

public struct ActionDTO: Codable, Sendable, Equatable {
  public let kind: String
  public let target: String
  public let payload: String?

  public init(kind: String, target: String, payload: String?) {
    self.kind = kind
    self.target = target
    self.payload = payload
  }

  public init(_ action: Action) {
    self.init(
      kind: action.kind.rawValue,
      target: action.target?.label ?? "",
      payload: action.payload
    )
  }
}

/// One question in a batch.
///
/// Jev evaluates every question in a batch against one shared state, in
/// parallel — latency measured flat from 1 to 25 questions, while each question
/// costs ~31 input tokens and ~18 output tokens, and **output tokens are free**.
/// So: ask every question the step might need, and ask no question no branch
/// reads.
public enum Question: Sendable, Equatable {
  /// 0–1. Returns no `confidence` field — that is a documented asymmetry, not
  /// an omission.
  case noul(instructions: String, whenTrue: String, whenFalse: String)
  /// Max 255 options, documented. `criteria` maps option id → label.
  case choice(instructions: String, criteria: [String: String])
  /// 2–10 ordered levels, documented.
  case score(instructions: String, levels: [String])
}

extension Question: Encodable {
  private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
  private enum NoulCriteriaKeys: String, CodingKey { case `true`, `false` }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .noul(let instructions, let whenTrue, let whenFalse):
      try c.encode("noul", forKey: .type)
      try c.encode(instructions, forKey: .instructions)
      var crit = c.nestedContainer(keyedBy: NoulCriteriaKeys.self, forKey: .criteria)
      try crit.encode(whenTrue, forKey: .true)
      try crit.encode(whenFalse, forKey: .false)
    case .choice(let instructions, let criteria):
      try c.encode("choice", forKey: .type)
      try c.encode(instructions, forKey: .instructions)
      try c.encode(criteria, forKey: .criteria)
    case .score(let instructions, let levels):
      try c.encode("score", forKey: .type)
      try c.encode(instructions, forKey: .instructions)
      try c.encode(levels, forKey: .criteria)
    }
  }
}

struct JevRequest: Encodable, Sendable {
  let state: StepContext
  /// Pinned. Never `jev-latest` — an alias moves when a release ships and
  /// every threshold in this project was tuned against one version.
  let model: String
  let questions: [String: Question]
}

// MARK: - Response

public struct ScoreAnswer: Sendable, Equatable, Codable {
  public let score: Double
  public let legend: [String: String]
  public let probabilities: [String: Double]
  public let confidence: Double
}

/// One answer from a batch.
///
/// **`probabilities` and `legend` are keyed by `String`, not `Int`.** The HTTP
/// API returns string keys; the *Python SDK* re-keys them by integer level. Any
/// Swift written from a Python example will declare `[Int: Double]` and fail to
/// decode. This is the single most likely bug in this integration.
public enum Answer: Sendable, Equatable {
  case noul(Double)
  case choice(ChoiceAnswer)
  case score(ScoreAnswer)
}

extension Answer: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type, noul, choice, probabilities, confidence, score, legend
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "noul":
      self = .noul(try c.decode(Double.self, forKey: .noul))
    case "choice":
      self = .choice(
        ChoiceAnswer(
          choice: try c.decode(String.self, forKey: .choice),
          probabilities: try c.decode([String: Double].self, forKey: .probabilities),
          confidence: try c.decode(Double.self, forKey: .confidence)
        )
      )
    case "score":
      self = .score(
        ScoreAnswer(
          score: try c.decode(Double.self, forKey: .score),
          legend: try c.decode([String: String].self, forKey: .legend),
          probabilities: try c.decode([String: Double].self, forKey: .probabilities),
          confidence: try c.decode(Double.self, forKey: .confidence)
        )
      )
    default:
      // An unknown primitive is thrown, never dropped. A silently skipped
      // answer becomes a default-valued probability at a decision site,
      // which is a safety-relevant wrong answer that looks like a right one.
      throw JevError.malformedResponse(field: "answers.type=\(type)")
    }
  }

  /// The Noul value, or `nil` if this answer is a different primitive.
  ///
  /// Never compare a Noul threshold against a Choice or a Score: Jev's own
  /// jaggedness page documents that structural invariants do not hold —
  /// `P(refund)` and `1 − P(NOT refund)` measured 0.70 and 0.58.
  public var noulValue: Double? {
    if case .noul(let v) = self { return v }
    return nil
  }

  public var choiceValue: ChoiceAnswer? {
    if case .choice(let v) = self { return v }
    return nil
  }
}

struct JevResponse: Decodable, Sendable {
  let model: String
  let answers: [String: Answer]
  let usage: Usage
}

/// The vendor's error body: `{"detail": "..."}`.
struct JevErrorBody: Decodable, Sendable {
  let detail: String?
}
