import CoreGraphics
import Foundation

@testable import Harness

/// Returns the same element list on every observation.
struct FakeSource: ElementSource {
  let kind: SourceKind = .ax
  var elements: [Element]
  /// Which element the keyboard is pointing at, by label. `nil` is a source
  /// that cannot tell — which is what every source used to be.
  var focusedLabel: String?
  func observe() async throws -> [Element] { elements }
  func focused(among elements: [Element]) async -> Element? {
    guard let focusedLabel else { return nil }
    return elements.first { $0.label == focusedLabel }
  }
}

/// Answers with one screen first and another after — the shape of a page that
/// is replaced by the thing a step did.
actor ChangingSource: ElementSource {
  nonisolated let kind: SourceKind = .ax
  private let first: [Element]
  private let then: [Element]
  private var seen = 0

  init(first: [Element], then: [Element]) {
    self.first = first
    self.then = then
  }

  func observe() async throws -> [Element] {
    seen += 1
    return seen <= 1 ? first : then
  }
}

/// A screen that says it is still arriving, for as long as the test wants.
actor LoadingSource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private let elements: [Element]
  private let loadingForObservations: Int
  private var seen = 0

  init(elements: [Element], loadingForObservations: Int) {
    self.elements = elements
    self.loadingForObservations = loadingForObservations
  }

  func observe() async throws -> [Element] {
    seen += 1
    return elements
  }

  func readiness() async -> String {
    seen <= loadingForObservations ? "loading" : "\(elements.count)"
  }
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
  /// Every context, in order. `lastContext` cannot answer a question about the
  /// step *before* the final one, and `verifyLastStep` makes a call of its own
  /// — so the interesting judgement is rarely the last.
  private(set) var contexts: [StepContext] = []
  /// How long each answer takes. A real Jev call is ~600 ms, and whether that
  /// is paid inside a wait or after it is the thing some tests are about.
  private let latency: Duration
  /// When each call started, measured from this judge's creation.
  private(set) var startedAt: [Duration] = []
  private let born = ContinuousClock.now

  init(_ script: [StepVerdict], latency: Duration = .zero) {
    self.script = script
    self.latency = latency
  }

  func step(_ context: StepContext, budgetRemaining: Duration) async throws -> StepVerdict {
    callCount += 1
    lastContext = context
    contexts.append(context)
    startedAt.append(born.duration(to: ContinuousClock.now))
    if latency > .zero { try? await Task.sleep(for: latency) }
    if script.count > 1 { return script.removeFirst() }
    return script[0]
  }
}

/// Records every action that reached execution.
actor RecordingExecutor: Executor, ExecutorProviding {
  private(set) var executed: [Action] = []
  var shouldFail = false
  /// Run when a step actually dispatches. A fake screen that changes on a
  /// counted observation is guessing how many times the loop reads the page
  /// before it acts — and that count moves whenever the readiness rules do.
  /// This lets the change be caused by the action, which is what it models.
  private let onExecute: (@Sendable () async -> Void)?

  init(onExecute: (@Sendable () async -> Void)? = nil) { self.onExecute = onExecute }

  nonisolated func executor(for ref: ElementRef?, kind: ActionKind) throws -> any Executor {
    self
  }

  func execute(_ action: Action) async throws -> ExecutionResult {
    executed.append(action)
    await onExecute?()
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
    label: String = "Compose", role: String = "AXButton", path: [Int] = [0],
    value: String = "", focused: Bool = false
  ) -> Element {
    Element(
      ref: .ax(path: path, role: role, label: label),
      role: role, label: label, enabled: true, value: value, focused: focused,
      inViewport: true,
      bounds: CGRect(x: 0, y: 0, width: 40, height: 20)
    )
  }

  /// A web element. `handle` is the identity the snapshot's WeakMap hands out,
  /// which is what survives the element's own text changing.
  static func domElement(
    handle: String, label: String = "Compose", role: String = "button"
  ) -> Element {
    Element(
      ref: .dom(handle: handle, selector: "\(role)[\(label)]", label: label, submitLabel: ""),
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
    executor: any ExecutorProviding = RecordingExecutor(),
    hud: any HUDBridge = HeadlessHUD(),
    elements: [Element] = [Make.element(), Make.element(label: "Home", path: [1])],
    taskContext: String = "",
    focusedLabel: String? = nil,
    budget: Budget = Budget(),
    settleTimeout: Duration = .zero,
    source: (any ElementSource)? = nil,
    capture: (any ScreenCapturing)? = nil,
    // Defaults to ON so that every test written about the gate keeps testing
    // the gate. `Constants.Safety.askBeforeIrreversible` is what ships, and
    // exactly one test asserts that value — see "the sheet is off by default".
    asksBeforeIrreversible: Bool = true
  ) -> AgentLoop {
    AgentLoop(
      task: "test task", taskContext: taskContext, plan: plan,
      sessionID: "s_test", pid: 0,
      source: source ?? FakeSource(elements: elements, focusedLabel: focusedLabel),
      jev: judge, executors: executor, hud: hud,
      capture: capture,
      budget: budget,
      asksBeforeIrreversible: asksBeforeIrreversible,
      // The fake screen never changes, so a real settle would be paid in full
      // on every dispatched step. That is 1.2s each, against a suite that
      // otherwise runs in milliseconds.
      settleTimeout: settleTimeout
    )
  }
}

/// A page that finishes arriving and then keeps growing slowly, the way a feed
/// does. The element list changes exactly once and then holds still, while the
/// node count creeps up a few percent on every observation.
actor StreamingSource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private let before: [Element]
  private let after: [Element]
  private var nodes = 3_000
  private var acted = false

  init(before: [Element], after: [Element]) {
    self.before = before
    self.after = after
  }

  /// The step dispatched; the screen may now reflect it.
  func landed() { acted = true }

  func observe() async throws -> [Element] {
    // Three percent a poll — one more item in a timeline, never twice the same
    // number, and nowhere near a shell turning into a page.
    nodes += nodes / 32
    return acted ? after : before
  }

  func readiness() async -> String { "\(nodes)" }
}

/// A finished page that never stops claiming to be busy — X's home timeline,
/// which holds one visible progressbar on an idle, fully loaded screen. The
/// document is complete and the elements hold still; only the spinner argues.
actor SpinningSource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private let before: [Element]
  private let after: [Element]
  private var acted = false

  init(before: [Element], after: [Element]) {
    self.before = before
    self.after = after
  }

  /// The step dispatched; the screen may now reflect it.
  func landed() { acted = true }

  func observe() async throws -> [Element] { acted ? after : before }

  /// Complete, and busy, forever.
  func readiness() async -> String { "busy:2573" }
}

/// A page that never finishes arriving.
///
/// `readiness()` answers `loading` forever, which is what a site with a
/// permanent progress indicator looks like to the loop. Used to prove that a
/// step which is about to replace the page does not wait for it.
actor NeverReadySource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private let elements: [Element]

  init(elements: [Element] = [Make.element()]) { self.elements = elements }

  func observe() async throws -> [Element] { elements }
  func readiness() async -> String { "loading" }
}

/// Dispatches nothing, so the step never reaches `settle`. Lets a test time a
/// single phase of the loop without the settle window dominating it.
actor InertExecutor: Executor, ExecutorProviding {
  nonisolated func executor(for ref: ElementRef?, kind: ActionKind) throws -> any Executor {
    self
  }
  func execute(_ action: Action) async throws -> ExecutionResult {
    ExecutionResult(dispatched: false, via: .bidi)
  }
}

/// A page with a clock on it.
///
/// Every element keeps its identity and its role; one label counts down, once
/// per observation, forever. This is x.com's timeline with a video in it.
actor TickingSource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private var tick = 30
  private let others: Int

  init(others: Int = 5) { self.others = others }

  func observe() async throws -> [Element] {
    tick -= 1
    var elements = (0..<others).map {
      Make.domElement(handle: "e\($0)", label: "row \($0)")
    }
    elements.append(
      Make.domElement(handle: "e99", label: "a video, 0:\(tick) remaining"))
    return elements
  }

  func readiness() async -> String { "3000" }
}

/// A page that gains an element partway through settling.
///
/// Time-based rather than counted, because the thing under test is *when* the
/// change lands relative to the quiet window — after the speculative
/// judgement has been started, before the window closes.
actor ShiftingSource: ElementSource {
  nonisolated let kind: SourceKind = .bidi
  nonisolated var reportsReadiness: Bool { true }
  private let before: [Element]
  private let after: [Element]
  private let shiftAfter: Duration
  private var firstSeen: ContinuousClock.Instant?

  init(before: [Element], after: [Element], shiftAfter: Duration = .milliseconds(900)) {
    self.before = before
    self.after = after
    self.shiftAfter = shiftAfter
  }

  func observe() async throws -> [Element] {
    let start = firstSeen ?? ContinuousClock.now
    firstSeen = start
    return start.duration(to: ContinuousClock.now) >= shiftAfter ? after : before
  }

  func readiness() async -> String { "1000" }
}

/// A screen that answers differently once the action has landed.
///
/// Unlike `ChangingSource` this is driven by the executor rather than by a
/// count of observations, so a test about *what the action did* does not also
/// depend on how many times the loop reads the page before acting.
actor ActedSource: ElementSource {
  nonisolated let kind: SourceKind = .ax
  private let before: [Element]
  private let after: [Element]
  private var acted = false

  init(before: [Element], after: [Element]) {
    self.before = before
    self.after = after
  }

  func landed() { acted = true }
  func observe() async throws -> [Element] { acted ? after : before }
}

/// A capture that never succeeds — the intermittent Screen Recording failure,
/// made deterministic.
struct FailingCapture: ScreenCapturing {
  static let message = "the window vanished between the decision and the capture"

  func captureWithMarks(
    pid: pid_t, candidates: [Element], to url: URL
  ) async throws -> (path: String, frameHash: String) {
    throw ExecutionError.graphicsFailed(stage: Self.message)
  }
}
