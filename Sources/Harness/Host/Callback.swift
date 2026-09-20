import Foundation

/// The only field the host branches on.
///
/// Six cases, and **adding a seventh is an "ask first" boundary** — two
/// callbacks are what keep the host out of the per-step loop, and a third is how
/// it gets back in. SPEC.md § Boundaries.
public enum HostStatus: String, Codable, Sendable, CaseIterable {
  /// Text was not enough. The host reads the marked screenshot and resumes
  /// with an index.
  case needsEyes = "needs_eyes"
  /// The route was wrong. The host reads history plus candidates and resumes
  /// with new plan steps.
  case needsPlan = "needs_plan"
  /// Login wall, permission, CAPTCHA, paywall. **Terminal.** Never retried —
  /// retrying a login wall produces another login wall.
  case blocked
  case completed
  /// Every step ran, and the screen cannot say whether it worked.
  ///
  /// **`task_done` asks whether the screen *shows* the task complete, which is
  /// not the same question as whether it succeeded.** A publish is the case
  /// where they come apart: measured on Facebook, a post that had plainly gone
  /// up scored 0.02, because the feed the agent lands on does not show it —
  /// the posted text was in neither the element list nor the page text.
  ///
  /// Reporting that as `needs_plan` told the host the route was wrong and
  /// invited more steps for work that was already done. Reporting it as
  /// `completed` would be a claim nothing supports. This is the honest third
  /// answer: the mechanics all ran, and confirmation has to come from
  /// somewhere other than this screen.
  case unverified
  case failed
  case budgetExhausted = "budget_exhausted"
}

/// The single JSON object printed to stdout per invocation.
///
/// Exit code is 0 for any status the host can act on, and non-zero only for a
/// malformed invocation, so the host never has to parse prose. Logs go to
/// stderr — `Log`.
public struct HostResponse: Codable, Sendable {
  public let session: String
  public let status: HostStatus
  public let step: Int
  public let elapsedMilliseconds: Int
  public let costUSD: Double
  /// `needs_eyes` only: the screenshot with candidate boxes drawn as numbered marks.
  public let screenshot: String?
  /// `id → label`. Keys are `e`-prefixed, matching `act --target e17`.
  public let candidates: [String: String]?
  public let history: [String]
  /// One line naming the probability that caused this status, so a human
  /// reading a log months later can tell which gate fired.
  public let reason: String

  public init(
    session: String, status: HostStatus, step: Int, elapsedMilliseconds: Int,
    costUSD: Double, screenshot: String? = nil, candidates: [String: String]? = nil,
    history: [String] = [], reason: String
  ) {
    self.session = session
    self.status = status
    self.step = step
    self.elapsedMilliseconds = elapsedMilliseconds
    self.costUSD = costUSD
    self.screenshot = screenshot
    self.candidates = candidates
    self.history = history
    self.reason = reason
  }

  private enum CodingKeys: String, CodingKey {
    case session, status, step, screenshot, candidates, history, reason
    case elapsedMilliseconds = "elapsed_ms"
    case costUSD = "cost_usd"
  }

  /// Exactly one JSON object, newline-terminated.
  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

/// What the host sends back on `resume --eyes`.
///
/// **The answer is an index, never a coordinate.** Asking for a point measures
/// worse: ScreenSpot-Pro puts coordinate regression at 17.1, where numbered
/// marks took GPT-4V from 16.2 to 73.0.
///
/// The label is not decoration. 74.2% of pressable elements are icon-only and
/// the tier-3b detector returns boxes with no labels, so without this string
/// `LabelDenylist` has nothing to match on exactly those targets — ADR 0007 §3.
public struct EyesAnswer: Codable, Sendable, Equatable {
  /// `nil` means the target is genuinely absent from the screen.
  public let index: Int?
  public let label: String?

  public init(index: Int?, label: String?) {
    self.index = index
    self.label = label
  }

  public static let absent = EyesAnswer(index: nil, label: nil)
}
