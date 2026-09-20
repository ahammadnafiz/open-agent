import Foundation

/// A Jev `choice` answer. Carries `probabilities` because `confidence` alone
/// cannot see where the runner-up sits — see `isConfident(...)`.
public struct ChoiceAnswer: Sendable, Hashable, Codable {
  public let choice: String
  public let probabilities: [String: Double]
  public let confidence: Double

  public init(choice: String, probabilities: [String: Double], confidence: Double) {
    self.choice = choice
    self.probabilities = probabilities
    self.confidence = confidence
  }

  /// Gap between the top two candidate probabilities.
  ///
  /// Jev's `confidence` is `(n · p_max − 1) / (n − 1)` — derived and confirmed
  /// live, 4/4 exact matches on `jev-1.13`. It reads ONLY `p_max`, so
  /// `{0.60, 0.38, 0.02}` and `{0.60, 0.20, 0.20}` return an identical 0.40
  /// despite entirely different risk. For element selection the runner-up is
  /// exactly what matters: two candidates at 0.48 and 0.47 is a coin flip that
  /// `confidence` reports as unremarkable.
  ///
  /// A single-option Choice has no runner-up; its margin is 1.0 by definition.
  public var margin: Double {
    let p = probabilities.values.sorted(by: >)
    guard let top = p.first else { return 0 }
    return p.count > 1 ? top - p[1] : 1.0
  }
}

/// Everything one Jev batch returned about one step.
///
/// **Every field is a raw probability. Nothing in this type is a boolean.**
/// Thresholding happens exactly once, at the decision site, against a named
/// constant in `Constants`. See SPEC.md § Code Style.
public struct StepVerdict: Sendable, Codable {
  // Verification — about the step that just happened
  public let progressed: Double
  public let unchanged: Double
  public let blocked: Double
  public let taskDone: Double
  public let looping: Double
  /// Only asked when `task_context` is non-empty; `nil` otherwise. Asking about
  /// a context the task never named invents one.
  public let wrongContext: Double?

  // Selection — about the step about to happen
  public let target: ChoiceAnswer?
  public let sufficient: Double

  // Intent risk — about the planned step, not the resolved element
  public let riskDestructive: Double
  public let riskOutbound: Double
  public let riskCredential: Double

  /// Echoed from the response. An alias moving is a silent behavioural change
  /// and this is the only way to notice — `docs/host-contract.md` §6.
  public let modelVersion: String
  public let usage: Usage
  /// The only handle for vendor support. Logged on every step.
  public let requestID: String?

  public init(
    progressed: Double, unchanged: Double, blocked: Double, taskDone: Double,
    looping: Double, wrongContext: Double?, target: ChoiceAnswer?, sufficient: Double,
    riskDestructive: Double, riskOutbound: Double, riskCredential: Double,
    modelVersion: String, usage: Usage, requestID: String?
  ) {
    self.progressed = progressed
    self.unchanged = unchanged
    self.blocked = blocked
    self.taskDone = taskDone
    self.looping = looping
    self.wrongContext = wrongContext
    self.target = target
    self.sufficient = sufficient
    self.riskDestructive = riskDestructive
    self.riskOutbound = riskOutbound
    self.riskCredential = riskCredential
    self.modelVersion = modelVersion
    self.usage = usage
    self.requestID = requestID
  }

  /// `max`, never a mean. One confident red flag must win; averaging buries it.
  /// This is the aggregation that took the risk gate from 4/14 errors to 2/14
  /// in measurement — `docs/jev-questions.md` §2.4.
  public var riskMax: Double {
    max(riskDestructive, max(riskOutbound, riskCredential))
  }

  /// Whether the fast path may act without escalating to vision.
  ///
  /// Three independent gates, all of which must pass. `confidence` cannot see
  /// the runner-up, so `margin` is not redundant with it; `sufficient` is an
  /// unnormalised Noul and is the only thing that can say "none of these",
  /// which a Choice — whose probabilities sum to 1 — structurally cannot.
  public var passesSelectionGate: Bool {
    guard let target else { return false }
    return target.confidence >= Constants.Jev.selectionConfidence
      && target.margin >= Constants.Jev.selectionMargin
      && sufficient >= Constants.Jev.sufficient
  }
}

/// Tokens the request consumed, as the vendor reported them.
public struct Usage: Sendable, Codable, Hashable {
  public let inputTokens: Int
  public let outputTokens: Int

  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
  }

  /// Output tokens are free — `docs/jev-api-reference.md`, vendor `/models`.
  public var dollars: Double {
    Double(inputTokens) / 1_000_000.0 * Constants.Jev.inputPricePerMillionTokens
  }
}
