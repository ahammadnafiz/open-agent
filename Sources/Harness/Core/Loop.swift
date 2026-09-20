import Foundation

/// What one `run` or `resume` invocation produced.
public struct LoopResult: Sendable {
  public let status: HostStatus
  public let step: Int
  public let elapsed: Duration
  public let costUSD: Double
  public let candidates: [String: String]?
  public let screenshot: String?
  public let history: [String]
  public let reason: String
  public let steps: [Step]
}

/// Captures the focused window with candidate boxes drawn on as numbered marks.
///
/// Behind a protocol so the loop is testable with no screen, no TCC grant and no
/// pixels — `LoopTests` runs entirely offline.
public protocol ScreenCapturing: Sendable {
  /// - Returns: the saved path and a hash of the captured frame. The hash goes
  ///   in the step log; a `.captured` bbox is meaningless without the frame it
  ///   was measured in.
  func captureWithMarks(
    pid: pid_t, candidates: [Element], to url: URL
  ) async throws -> (path: String, frameHash: String)
}

/// The agent loop.
///
/// ```
///   OBSERVE ──► JUDGE ──► ROUTE ──► GATE ──► ACT
///      │          │         │        │        │
///      │          │         │        │        └─ narrating { execute }
///      │          │         │        └────────── deterministic, no model
///      │          │         └─────────────────── thresholds, named constants
///      │          └───────────────────────────── ONE Jev call, ~412 ms
///      └──────────────────────────────────────── filter to ≤255
/// ```
///
/// **One task at a time.** An actor, because concurrent tasks driving the same
/// screen is nonsense.
public actor AgentLoop {
  private let task: String
  private let taskContext: String
  private var plan: Plan
  private let sessionID: String
  private let source: any ElementSource
  private let jev: any StepJudge
  private let executors: any ExecutorProviding
  private let hud: any HUDBridge
  private let capture: (any ScreenCapturing)?
  private let artifactsDirectory: URL
  private let pid: pid_t

  private var budget: Budget
  private var ladder = RecoveryLadder()
  private var history: [String] = []
  private var steps: [Step] = []
  private var planIndex: Int
  private var stepIndex: Int
  private var screenBefore = ""
  private var lastAction: Action?
  /// The plan index of `lastAction`.
  ///
  /// The ladder is keyed on this, not on the monotonic `stepIndex`. A rung is
  /// "attempted at most once per step index", and the step being recovered is
  /// the *plan* step whose action failed — keying on the monotonic counter
  /// would hand every retry a fresh rung 0 and never escalate.
  private var lastPlanIndex = -1
  /// A mark the host picked off the screenshot, consumed by the next selection.
  ///
  /// Set only by `resume --eyes`. It overrides Jev's Choice for exactly one
  /// step — the step that escalated — and then clears. Verification still runs
  /// normally in the same batch, because the screen may have changed between the
  /// screenshot being taken and the host answering.
  private var pendingEyes: EyesAnswer?
  private var totalCost = 0.0

  /// Whether an irreversible step stops for a human. Injected so the tests can
  /// exercise both states; the shipped value is `Constants.Safety`, which
  /// explains why it is what it is.
  private let asksBeforeIrreversible: Bool

  /// How long to let the screen catch up after an action. Injected so the unit
  /// tests do not each pay a real settle against a fake screen that will never
  /// change — a suite that takes ten seconds stops being run.
  private let settleTimeout: Duration

  public init(
    task: String,
    taskContext: String = "",
    plan: Plan,
    sessionID: String,
    pid: pid_t,
    source: any ElementSource,
    jev: any StepJudge,
    executors: any ExecutorProviding,
    hud: any HUDBridge,
    capture: (any ScreenCapturing)? = nil,
    artifactsDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
    budget: Budget = Budget(),
    resumeFrom: LoopState? = nil,
    pendingEyes: EyesAnswer? = nil,
    asksBeforeIrreversible: Bool = Constants.Safety.askBeforeIrreversible,
    settleTimeout: Duration = Constants.Execution.settleTimeout
  ) {
    self.settleTimeout = settleTimeout
    self.asksBeforeIrreversible = asksBeforeIrreversible
    self.pendingEyes = pendingEyes
    self.task = task
    self.taskContext = taskContext
    self.plan = plan
    self.sessionID = sessionID
    self.pid = pid
    self.source = source
    self.jev = jev
    self.executors = executors
    self.hud = hud
    self.capture = capture
    self.artifactsDirectory = artifactsDirectory
    self.budget = resumeFrom?.budget ?? budget
    self.history = resumeFrom?.history ?? []
    self.planIndex = resumeFrom?.planIndex ?? 0
    self.stepIndex = resumeFrom?.stepIndex ?? 0
    self.screenBefore = resumeFrom?.screenBefore ?? ""
    self.totalCost = resumeFrom?.totalCost ?? 0
  }

  /// Everything that has to survive between `run` and `resume`, which are
  /// separate processes with gaps between them.
  public struct LoopState: Codable, Sendable {
    /// Carried, not recomputed.
    ///
    /// This was a computed `Budget()` and it meant every `resume` handed the
    /// task a fresh 40 steps, 90 seconds and $0.25. A task that escalated
    /// repeatedly was unbounded across invocations, which is precisely what
    /// SPEC.md § S4 says must not happen: *"No task exceeds 40 steps, 90 seconds
    /// of machine time, 3 vision escalations, 2 replans, or $0.25."* Ceilings
    /// that reset are not ceilings.
    public var budget: Budget
    public var history: [String]
    public var planIndex: Int
    public var stepIndex: Int
    public var screenBefore: String
    public var totalCost: Double

    public init(
      budget: Budget = Budget(), history: [String], planIndex: Int, stepIndex: Int,
      screenBefore: String, totalCost: Double
    ) {
      self.budget = budget
      self.history = history
      self.planIndex = planIndex
      self.stepIndex = stepIndex
      self.screenBefore = screenBefore
      self.totalCost = totalCost
    }
  }

  public func state() -> LoopState {
    LoopState(
      budget: budget, history: history, planIndex: planIndex, stepIndex: stepIndex,
      screenBefore: screenBefore, totalCost: totalCost
    )
  }

  // MARK: - The loop

  public func run() async -> LoopResult {
    let started = ContinuousClock.now

    while true {
      if let ceiling = budget.exhausted() {
        return result(
          .budgetExhausted, since: started, reason: "budget ceiling: \(ceiling.rawValue)")
      }
      guard !plan.isExhausted(at: planIndex) else {
        // The plan ran out and Jev never said the task was done. That is
        // a route problem, not a failure — the host can extend it.
        return result(.needsPlan, since: started, reason: "plan exhausted at step \(planIndex)")
      }

      let planStep = plan.steps[planIndex]
      let stepStarted = ContinuousClock.now

      // ── OBSERVE ──────────────────────────────────────────────────
      let candidates: CandidateSet
      do {
        candidates = try CandidateFilter.reduce(try await source.observe())
      } catch let error as CandidateError {
        // Too many candidates escalates to vision rather than silently
        // truncating. Truncation would remove the correct answer without
        // anyone noticing, which is the worst failure available.
        return await escalate(since: started, reason: "\(error)", candidates: nil)
      } catch {
        return result(.failed, since: started, reason: "perception failed: \(error)")
      }

      let screenNow = candidates.describe()

      // ── JUDGE ── one batched Jev call: verification + selection + risk
      let verdict: StepVerdict
      do {
        verdict = try await jev.step(
          StepContext(
            task: task,
            planStep: PlanStepDTO(planStep),
            lastAction: lastAction.map(ActionDTO.init),
            screenBefore: screenBefore,
            screenNow: screenNow,
            recentHistory: Array(history.suffix(Constants.Jev.historyWindow)),
            candidates: candidates.criteria,
            taskContext: taskContext
          ),
          budgetRemaining: Constants.Budget.stepTimeout
        )
      } catch {
        return result(.failed, since: started, reason: "judgment failed: \(error)")
      }
      budget.chargeDollars(verdict.usage.dollars)
      totalCost += verdict.usage.dollars

      // ── ROUTE ────────────────────────────────────────────────────
      if let routed = await route(
        verdict: verdict, candidates: candidates, since: started
      ) {
        return routed
      }

      // Steps that name no on-screen element skip selection entirely. `openApp`
      // is the first step of the v1 reference task, and routing it through
      // candidate selection made it unreachable.
      if !PlanStep.needsTarget(planStep.kind) {
        let action = Action(
          kind: planStep.kind, target: nil, payload: planStep.payload,
          rationale: planStep.target
        )
        if let early = await performTargetless(
          action, verdict: verdict, planStep: planStep, since: started, stepStarted: stepStarted
        ) {
          return early
        }
        continue
      }

      // ── SELECT ───────────────────────────────────────────────────
      let element: Element
      if let eyes = pendingEyes {
        // The host looked at the marked screenshot and answered with a number.
        // Marks are drawn 1-based, so mark N is candidate N-1.
        pendingEyes = nil
        guard let index = eyes.index, candidates.elements.indices.contains(index - 1) else {
          return result(
            .needsPlan, since: started,
            reason: "the host answered with mark \(eyes.index.map(String.init) ?? "none"), "
              + "which is not on the current screen — the route needs to change",
            candidates: candidates.criteria
          )
        }
        let picked = candidates.elements[index - 1]
        // The label the host supplied rides along as `visionLabel`. It is
        // attacker-influenced — it was read off pixels — and admissible anyway,
        // because `classify` can only ever RAISE on it. Without it, an icon-only
        // target has nothing `LabelDenylist` can match — ADR 0007 §3.
        element = Element(
          ref: picked.ref, role: picked.role, label: picked.label,
          enabled: picked.enabled, inViewport: picked.inViewport, bounds: picked.bounds,
          visionLabel: eyes.label ?? picked.visionLabel
        )
        Log.info("using host-selected mark \(index): \(element.label)")
      } else if planStep.kind == .pressKey,
        let ax = source as? AXSource,
        let focused = ax.focused(among: candidates.elements)
      {
        // A keystroke goes where focus is, not where a model guessed. See
        // `AXSource.focused(among:)` — this is the same element ADR 0008 says
        // `enter` must be classified against.
        element = focused
        Log.info("pressKey targets the focused element: \(element.label)")
      } else if verdict.passesSelectionGate,
        let choice = verdict.target,
        let resolved = candidates.element(forID: choice.choice)
      {
        element = resolved
      } else {
        return await escalate(
          since: started,
          reason: selectionReason(verdict),
          candidates: candidates
        )
      }

      let action = Action(
        kind: planStep.kind,
        target: element.ref,
        payload: planStep.payload,
        rationale: planStep.target
      )

      // ── GATE ── deterministic, no model result reaches it ─────────
      let effective = Irreversibility.classify(
        action, target: element, declaredByPlanner: planStep.declaredIrreversible
      )
      var confirmed = false
      // The classification still happens and is still logged; only the stop is
      // optional. `Constants.Safety.askBeforeIrreversible` says why.
      if asksBeforeIrreversible,
        Irreversibility.requiresConfirmation(effective, riskMax: verdict.riskMax)
      {
        // Human time is NEVER charged to the machine-time budget.
        let approved = await hud.confirm(
          ConfirmationRequest(
            actionKind: action.kind,
            targetLabel: element.label.isEmpty ? (element.visionLabel ?? "") : element.label,
            payload: action.payload,
            rationale: action.rationale,
            becauseIrreversible: effective == .irreversible,
            riskMax: verdict.riskMax
          )
        )
        guard approved else {
          return result(.failed, since: started, reason: "declined at the confirmation sheet")
        }
        confirmed = true
      }

      // ── ACT ── narration and execution are one call ───────────────
      let executionResult: ExecutionResult
      do {
        let executor = try executors.executor(for: action.target, kind: action.kind)
        executionResult = try await hud.narrating(action, target: element) {
          try await executor.execute(action)
        }
      } catch {
        Log.warn("execution failed at step \(stepIndex): \(error)")
        executionResult = ExecutionResult(dispatched: false, via: element.ref.sourceKind)
      }

      // Let the application actually do what it was asked before the next
      // iteration reads the screen and judges whether it did. `screenNow` is
      // the screen as it was *before* this action, which is exactly what the
      // next observation has to differ from.
      if executionResult.dispatched { await settle(from: screenNow) }

      // ── RECORD ───────────────────────────────────────────────────
      // Verification of THIS step arrives in the NEXT iteration's batch, so the
      // verdict recorded here is the one that *selected* the action.
      record(
        action: action, result: executionResult, sourceKind: element.ref.sourceKind,
        verdict: verdict, confirmed: confirmed, stepStarted: stepStarted,
        screenNow: screenNow
      )
    }
  }

  /// Runs a step that names no on-screen element.
  ///
  /// Shares the gate and the step log with the targeted path — a targetless
  /// action is still an action, and `openApp` on the wrong app is still worth
  /// confirming if a denylist term is in its payload.
  private func performTargetless(
    _ action: Action,
    verdict: StepVerdict,
    planStep: PlanStep,
    since started: ContinuousClock.Instant,
    stepStarted: ContinuousClock.Instant
  ) async -> LoopResult? {
    let effective = Irreversibility.classify(
      action, target: nil, declaredByPlanner: planStep.declaredIrreversible
    )
    var confirmed = false
    if asksBeforeIrreversible,
      Irreversibility.requiresConfirmation(effective, riskMax: verdict.riskMax)
    {
      let approved = await hud.confirm(
        ConfirmationRequest(
          actionKind: action.kind, targetLabel: action.payload ?? planStep.target,
          payload: action.payload, rationale: planStep.target,
          becauseIrreversible: effective == .irreversible, riskMax: verdict.riskMax
        )
      )
      guard approved else {
        return result(.failed, since: started, reason: "declined at the confirmation sheet")
      }
      confirmed = true
    }

    let executionResult: ExecutionResult
    do {
      let executor = try executors.executor(for: nil, kind: action.kind)
      executionResult = try await hud.narrating(action, target: nil) {
        try await executor.execute(action)
      }
    } catch {
      Log.warn("execution failed at step \(stepIndex): \(error)")
      executionResult = ExecutionResult(dispatched: false, via: source.kind)
    }

    // **The steps that need this most were the ones not getting it.** Settling
    // lived only on the targeted path, and `navigate` and `openApp` are
    // targetless — so the two actions that replace the entire screen were the
    // two that were judged immediately, before anything had arrived. Instagram
    // was read at 157 nodes with no links and `readyState: loading`, and the
    // next step escalated with "no candidates to choose from".
    if executionResult.dispatched { await settle(from: screenBefore) }

    record(
      action: action, result: executionResult, sourceKind: source.kind,
      verdict: verdict, confirmed: confirmed, stepStarted: stepStarted,
      screenNow: screenBefore
    )
    return nil
  }

  /// Appends one step to the audit log and advances the loop's cursors.
  ///
  /// SPEC.md § Boundaries: *"Log every step with its verdict, its cost, and the
  /// model version that answered."* All three are written here, to stderr, on
  /// every step — a log that only appears on failure is a log nobody has when
  /// they need it.
  /// Waits for the screen to change after an action, bounded.
  ///
  /// A timeout is not a failure and is not reported as one: plenty of actions
  /// genuinely change nothing visible, and deciding which is Jev's job. All
  /// this does is make sure that when Jev is asked, it is looking at the screen
  /// *after* the action rather than the screen before it.
  ///
  /// See `Constants.Execution.settleTimeout` for what this cost buys.
  private func settle(from before: String) async {
    let deadline = ContinuousClock.now.advanced(by: settleTimeout)
    var previous: String?
    var stable = 0
    while ContinuousClock.now < deadline {
      try? await Task.sleep(for: Constants.Execution.settlePollInterval)
      // **A failed observation here means "not yet", not "give up".** During a
      // navigation the document is being replaced, so the snapshot script has
      // nothing to run against and throws — and returning on that turned the
      // whole settle into a single failed poll. The next step then observed a
      // page that had not finished arriving and escalated with "no candidates
      // to choose from", on a page that had twelve of them a moment later.
      guard let elements = try? await source.observe(),
        let described = try? CandidateFilter.reduce(elements).describe()
      else { continue }
      // The element list *and* how finished the page claims to be. A shell with
      // a navigation rail on it is stable at twelve elements while the content
      // the step needs is still being built — see `ElementSource.readiness()`.
      let readiness = await source.readiness()
      // A page that reports itself unfinished is never settled, no matter how
      // long it has looked the same. Bounded by the ceiling either way.
      if readiness == "loading" {
        previous = nil
        continue
      }
      let now = described + "\u{1F}" + readiness
      // **Changed is not the same as finished.** Returning on the first
      // difference was enough for a click, and wrong for a navigation: a
      // single-page application paints its chrome, which is a change, and then
      // fills in the content the step actually needs. Instagram reported
      // `readyState: loading` with a navigation bar and no page — a step judged
      // there sees somewhere that exists and has nothing on it.
      //
      // So: wait for it to change, then wait for it to stop changing. Two
      // consecutive identical observations is the cheapest definition of
      // "settled" that does not require knowing what the page is.
      // **A screen with nothing on it is never "settled".** The rule used to be
      // "changed, then stable", and a page still painting its skeleton is
      // stable at empty — Instagram reported 157 nodes, zero links, zero
      // buttons and `readyState: loading`, twice in a row, and that counted as
      // settled. The next step then escalated with "no candidates to choose
      // from" against a page that was still arriving.
      //
      // Waiting for two identical NON-EMPTY observations is both simpler and
      // stricter. A step that genuinely changes nothing still returns in two
      // polls; a page that has not finished is waited out to the ceiling, which
      // is the outcome worth paying for.
      if !now.isEmpty, now == previous {
        stable += 1
        if stable >= Constants.Execution.settleStableChecks { return }
      } else {
        stable = 0
      }
      previous = now
    }
  }

  private func record(
    action: Action,
    result executionResult: ExecutionResult,
    sourceKind: SourceKind,
    verdict: StepVerdict,
    confirmed: Bool,
    stepStarted: ContinuousClock.Instant,
    screenNow: String
  ) {
    let stepElapsed = ContinuousClock.now - stepStarted
    budget.chargeStep()
    budget.chargeMachineTime(stepElapsed)

    let step = Step(
      index: stepIndex, action: action, result: executionResult,
      source: sourceKind, usedVision: false, cost: Cost(verdict.usage),
      elapsedMilliseconds: Int(stepElapsed.inSeconds * 1000),
      modelVersion: verdict.modelVersion, requestID: verdict.requestID,
      confirmed: confirmed,
      verdict: VerdictSummary(verdict)
    )
    steps.append(step)
    Log.info(
      "step \(stepIndex) \(action.summary) — dispatched=\(executionResult.dispatched) "
        + "progressed=\(fmt(verdict.progressed)) risk=\(fmt(verdict.riskMax)) "
        + "cost=$\(String(format: "%.6f", verdict.usage.dollars)) "
        + "model=\(verdict.modelVersion) request-id=\(verdict.requestID ?? "-")"
        + (confirmed ? " CONFIRMED" : "")
    )

    history.append(action.summary)
    screenBefore = screenNow
    lastAction = action
    lastPlanIndex = planIndex
    stepIndex += 1
    planIndex += 1
  }

  // MARK: - Routing

  /// Returns a terminal result, or `nil` to continue to selection.
  private func route(
    verdict: StepVerdict,
    candidates: CandidateSet,
    since started: ContinuousClock.Instant
  ) async -> LoopResult? {

    if verdict.taskDone >= Constants.Jev.taskDone {
      return result(.completed, since: started, reason: "task_done \(fmt(verdict.taskDone))")
    }

    // Never retried. Retrying a login wall produces another login wall, and
    // the agent has no credential to offer.
    if verdict.blocked >= Constants.Jev.blocked {
      return result(.blocked, since: started, reason: "blocked \(fmt(verdict.blocked))")
    }

    // The five verification questions compare `screen_before` to
    // `screen_now`. On step 0 there is no last action, so they are answering
    // about nothing and their values must not route anything.
    guard lastAction != nil else { return nil }

    if verdict.looping >= Constants.Jev.looping {
      return await escalate(
        since: started, reason: "looping \(fmt(verdict.looping))", candidates: candidates
      )
    }

    // Right screen, wrong instance. Every other verification question
    // answers correctly while the agent works in the wrong account.
    if let wrongContext = verdict.wrongContext, wrongContext >= Constants.Jev.wrongContext {
      return applyRecovery(
        ladder.next(for: lastPlanIndex, verdict: verdict, budget: budget),
        since: started, reason: "wrong_context \(fmt(wrongContext))", candidates: candidates
      )
    }

    if verdict.progressed < Constants.Jev.progressed {
      return applyRecovery(
        ladder.next(for: lastPlanIndex, verdict: verdict, budget: budget),
        since: started,
        reason: "progressed \(fmt(verdict.progressed)) unchanged \(fmt(verdict.unchanged))",
        candidates: candidates
      )
    }
    return nil
  }

  private func applyRecovery(
    _ recovery: Recovery,
    since started: ContinuousClock.Instant,
    reason: String,
    candidates: CandidateSet
  ) -> LoopResult? {
    switch recovery {
    case .retry:
      // Rung 0 re-attempts the action that failed, which lives at
      // `lastPlanIndex` — NOT the step the loop had moved on to. The
      // screen was already re-observed and re-judged this iteration, so
      // returning `nil` lets selection proceed against the current
      // verdict, which is exactly what "retry the same action" means.
      Log.info("ladder rung 0: retrying plan step \(lastPlanIndex) — \(reason)")
      planIndex = max(0, lastPlanIndex)
      return nil
    case .escalate:
      budget.chargeEscalation()
      return result(
        .needsEyes, since: started, reason: reason,
        candidates: candidates.criteria
      )
    case .replan:
      budget.chargeReplan()
      return result(
        .needsPlan, since: started, reason: reason, candidates: candidates.criteria
      )
    case .surface:
      return result(.failed, since: started, reason: "ladder exhausted — \(reason)")
    }
  }

  /// Escalation returns to the host with a marked screenshot when capture is
  /// available, and with the element list alone when it is not.
  private func escalate(
    since started: ContinuousClock.Instant,
    reason: String,
    candidates: CandidateSet?
  ) async -> LoopResult {
    budget.chargeEscalation()
    var screenshotPath: String?

    if let capture, let candidates {
      let url =
        artifactsDirectory
        .appending(path: sessionID)
        .appending(path: "step-\(String(format: "%02d", stepIndex)).png")
      do {
        let captured = try await capture.captureWithMarks(
          pid: pid, candidates: candidates.elements, to: url
        )
        screenshotPath = captured.path
      } catch {
        // An escalation without pixels is still actionable — the host
        // gets the element list and can answer `none`.
        Log.warn("capture failed, escalating without a screenshot: \(error)")
      }
    }

    return result(
      .needsEyes, since: started, reason: reason,
      candidates: candidates?.criteria, screenshot: screenshotPath
    )
  }

  private func selectionReason(_ verdict: StepVerdict) -> String {
    guard let target = verdict.target else {
      return "no candidates to choose from"
    }
    if verdict.sufficient < Constants.Jev.sufficient {
      return "sufficient \(fmt(verdict.sufficient)) — the target is not in the element list"
    }
    if target.confidence < Constants.Jev.selectionConfidence {
      return "selection confidence \(fmt(target.confidence))"
    }
    return "selection margin \(fmt(target.margin)) — top two candidates are too close"
  }

  // MARK: - Helpers

  private func result(
    _ status: HostStatus,
    since started: ContinuousClock.Instant,
    reason: String,
    candidates: [String: String]? = nil,
    screenshot: String? = nil
  ) -> LoopResult {
    LoopResult(
      status: status,
      step: stepIndex,
      elapsed: ContinuousClock.now - started,
      costUSD: totalCost,
      candidates: candidates,
      screenshot: screenshot,
      history: history,
      reason: reason,
      steps: steps
    )
  }

  private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}
