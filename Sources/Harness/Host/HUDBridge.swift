import Foundation

/// What a human is asked to approve. **The exact payload, never a summary.**
///
/// A summary is where an approval boundary quietly stops meaning anything: the
/// user approves "send a message" and the message is not the one they read.
public struct ConfirmationRequest: Sendable, Equatable {
  public let actionKind: ActionKind
  /// The element's own name, as the source or vision reported it.
  public let targetLabel: String
  /// Verbatim. The text to be typed, the URL, the key.
  public let payload: String?
  /// One line explaining why this step is happening.
  public let rationale: String
  /// Why approval is being asked: the deterministic boundary, or advisory risk.
  public let becauseIrreversible: Bool
  public let riskMax: Double

  public init(
    actionKind: ActionKind, targetLabel: String, payload: String?,
    rationale: String, becauseIrreversible: Bool, riskMax: Double
  ) {
    self.actionKind = actionKind
    self.targetLabel = targetLabel
    self.payload = payload
    self.rationale = rationale
    self.becauseIrreversible = becauseIrreversible
    self.riskMax = riskMax
  }

  /// The sentence shown in the sheet's title.
  ///
  /// A keystroke is rendered as what it will *activate*, never as the bare key:
  /// "Press Enter" tells the user nothing, and ADR 0008 requires "Press Enter,
  /// which will activate **Send**".
  public var headline: String {
    switch actionKind {
    case .pressKey where payload == Key.enter.rawValue && !targetLabel.isEmpty:
      "Press Enter, which will activate \(targetLabel)"
    case .pressKey:
      "Press \(payload ?? "a key")"
    default:
      targetLabel.isEmpty
        ? actionKind.rawValue.capitalized
        : "\(actionKind.rawValue.capitalized) \(targetLabel)"
    }
  }
}

/// The overlay and the approval sheet, reached from the headless loop.
///
/// `Harness` never imports AppKit; the executable implements this and injects
/// it. That boundary is what keeps the library testable and lets `Probe` run the
/// loop with no UI at all.
public protocol HUDBridge: Sendable {

  /// **The only supported shape for acting.**
  ///
  /// Not `overlay.move(…)` followed by `executor.execute(…)`. Two calls can
  /// drift, and an overlay that rings element X while the executor acts on
  /// element Y is worse than no overlay at all: it is a confident, legible lie
  /// about what just happened, and the user has been trained by every correct
  /// step before it to believe it. Wrapping execution makes the two
  /// structurally inseparable.
  func narrating(
    _ action: Action,
    target: Element?,
    _ body: @Sendable () async throws -> ExecutionResult
  ) async throws -> ExecutionResult

  /// Blocks until a human clicks. **The only unbounded wait in the system.**
  ///
  /// Time spent here is never charged against the task budget — a task must
  /// not die because the user read carefully.
  ///
  /// There is no flag, environment variable or host instruction that can
  /// answer this. Page text reaches the host's context by construction, and a
  /// measured semantic reframing moved a Jev risk score from 0.98 to 0.42.
  /// Anything expressible as an argument is eventually expressible by an
  /// injected instruction. A window is not.
  func confirm(_ request: ConfirmationRequest) async -> Bool
}

/// A bridge that draws nothing and approves nothing.
///
/// Used by `Probe` and by `LoopTests`. **It denies every confirmation**, because
/// a no-UI default that auto-approves would be a hole in the one boundary that
/// cannot be recovered from.
public struct HeadlessHUD: HUDBridge {
  public init() {}

  public func narrating(
    _ action: Action,
    target: Element?,
    _ body: @Sendable () async throws -> ExecutionResult
  ) async throws -> ExecutionResult {
    try await body()
  }

  public func confirm(_ request: ConfirmationRequest) async -> Bool {
    Log.warn("headless: refusing to approve '\(request.headline)' — no human present")
    return false
  }
}
