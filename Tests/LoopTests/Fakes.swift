import CoreGraphics
import Foundation

@testable import Harness

/// Returns the same element list on every observation.
struct FakeSource: ElementSource {
  let kind: SourceKind = .ax
  var elements: [Element]
  func observe() async throws -> [Element] { elements }
}

struct FailingSource: ElementSource {
  let kind: SourceKind = .ax
  let error: any Error
  func observe() async throws -> [Element] { throw error }
}

/// Replays scripted verdicts, one per call, then repeats the last forever.
actor ScriptedJudge: StepJudge {
  private var script: [StepVerdict]
  private(set) var callCount = 0
  private(set) var lastContext: StepContext?

  init(_ script: [StepVerdict]) { self.script = script }

  func step(_ context: StepContext, budgetRemaining: Duration) async throws -> StepVerdict {
    callCount += 1
    lastContext = context
    if script.count > 1 { return script.removeFirst() }
    return script[0]
  }
}

/// Records every action that reached execution.
actor RecordingExecutor: Executor, ExecutorProviding {
  private(set) var executed: [Action] = []
  var shouldFail = false

  nonisolated func executor(for ref: ElementRef?) throws -> any Executor { self }

  func execute(_ action: Action) async throws -> ExecutionResult {
    executed.append(action)
    if shouldFail { throw ExecutionError.axFailed(code: -1) }
    return ExecutionResult(dispatched: true, via: .ax)
  }

  func setShouldFail(_ value: Bool) { shouldFail = value }
}

/// Records confirmations and answers with a fixed decision.
actor RecordingHUD: HUDBridge {
  private(set) var confirmations: [ConfirmationRequest] = []
  private(set) var narratedActions: [Action] = []
  private let approve: Bool

  init(approve: Bool) { self.approve = approve }

  func narrating(
    _ action: Action, target: Element?,
    _ body: @Sendable () async throws -> ExecutionResult
  ) async throws -> ExecutionResult {
    narratedActions.append(action)
    return try await body()
  }

  func confirm(_ request: ConfirmationRequest) async -> Bool {
    confirmations.append(request)
    return approve
  }
}

enum Make {
  static func element(
    label: String = "Compose", role: String = "AXButton", path: [Int] = [0]
  ) -> Element {
    Element(
      ref: .ax(path: path, role: role, label: label),
      role: role, label: label, enabled: true, inViewport: true,
      bounds: CGRect(x: 0, y: 0, width: 40, height: 20)
    )
  }

  /// A verdict with everything inert. Each test overrides only the field it
  /// is about, so a routing assertion cannot pass for an unrelated reason.
  static func verdict(
    progressed: Double = 0.97,
    unchanged: Double = 0.03,
    blocked: Double = 0.02,
    taskDone: Double = 0.05,
    looping: Double = 0.04,
    wrongContext: Double? = nil,
    choice: String? = "e0",
    confidence: Double = 0.95,
    probabilities: [String: Double] = ["e0": 0.95, "e1": 0.05],
    sufficient: Double = 0.93,
    riskDestructive: Double = 0.01,
    riskOutbound: Double = 0.01,
    riskCredential: Double = 0.01
  ) -> StepVerdict {
    StepVerdict(
      progressed: progressed, unchanged: unchanged, blocked: blocked,
      taskDone: taskDone, looping: looping, wrongContext: wrongContext,
      target: choice.map {
        ChoiceAnswer(choice: $0, probabilities: probabilities, confidence: confidence)
      },
      sufficient: sufficient,
      riskDestructive: riskDestructive, riskOutbound: riskOutbound,
      riskCredential: riskCredential,
      modelVersion: Constants.Models.jev,
      usage: Usage(inputTokens: 1_000, outputTokens: 150),
      requestID: "req_test"
    )
  }

  static func plan(_ kinds: [ActionKind], declaredIrreversible: Bool = false) -> Plan {
    Plan(
      steps: kinds.map {
        PlanStep(
          kind: $0, target: "the \($0.rawValue) target", payload: nil,
          declaredIrreversible: declaredIrreversible)
      })
  }

  static func loop(
    plan: Plan,
    judge: ScriptedJudge,
    executor: RecordingExecutor = RecordingExecutor(),
    hud: any HUDBridge = HeadlessHUD(),
    elements: [Element] = [Make.element(), Make.element(label: "Home", path: [1])],
    taskContext: String = "",
    budget: Budget = Budget(),
    // Defaults to ON so that every test written about the gate keeps testing
    // the gate. `Constants.Safety.askBeforeIrreversible` is what ships, and
    // exactly one test asserts that value — see "the sheet is off by default".
    asksBeforeIrreversible: Bool = true
  ) -> AgentLoop {
    AgentLoop(
      task: "test task", taskContext: taskContext, plan: plan,
      sessionID: "s_test", pid: 0,
      source: FakeSource(elements: elements),
      jev: judge, executors: executor, hud: hud,
      budget: budget,
      asksBeforeIrreversible: asksBeforeIrreversible,
      // The fake screen never changes, so a real settle would be paid in full
      // on every dispatched step. That is 1.2s each, against a suite that
      // otherwise runs in milliseconds.
      settleTimeout: .zero
    )
  }
}
