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
  /// Set by ladder rung 0. The step it wants re-attempted is not the step this
  /// iteration already picked up, so the iteration has to start again.
  private var rewoundForRetry = false

  /// A judgement started before the step that needs it — see `beginSpeculation`.
  ///
  /// Held as three pieces rather than one struct because the shape and the plan
  /// index have to be checked *without* waiting for the verdict. Awaiting a
  /// judgement that is about to be thrown away would spend exactly the time
  /// this exists to save.
  private var speculationIndex: Int?
  private var speculationShape: String?
  private var speculationTask: Task<StepVerdict?, Never>?
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
        return await verifyLastStep(since: started)
      }

      let planStep = plan.steps[planIndex]
      let stepStarted = ContinuousClock.now

      // ── LOOK BEFORE LOOKING ──────────────────────────────────────
      // Read the room before reading the screen.
      //
      // `settle` covers the gap *after* an action, but nothing covered the
      // first step of a run, or a step whose predecessor dispatched nothing.
      // So a task starting on a page that was still arriving was judged
      // against a half-built screen, and the pointer set off toward an element
      // whose neighbours had not rendered yet. The user watched it happen:
      // *"without waiting for the whole loading of the site, the cursor moved
      // — first load, understand, then do things."*
      let readyStarted = ContinuousClock.now
      await waitUntilReady(before: planStep.kind)
      let readyMilliseconds = readyStarted.milliseconds()

      // ── OBSERVE ──────────────────────────────────────────────────
      let observeStarted = ContinuousClock.now
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

      let observeMilliseconds = observeStarted.milliseconds()

      // ── JUDGE ── one batched Jev call: verification + selection + risk
      //
      // Unless the previous step already made it. `settle` starts this exact
      // call once the screen has held still for half its quiet window, and the
      // answer is admissible only if the screen is still the same shape now —
      // same plan step, same set of things that can be acted on. Anything else
      // and it is dropped unread. See `beginSpeculation`.
      let judgeStarted = ContinuousClock.now
      var verdict: StepVerdict?
      var alreadyCharged = false
      if speculationIndex == planIndex, speculationShape == candidates.shape(),
        let ahead = speculationTask
      {
        verdict = await ahead.value
        alreadyCharged = verdict != nil
      }
      clearSpeculation()

      if verdict == nil {
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
      }
      guard let verdict else {
        return result(.failed, since: started, reason: "judgment failed: no verdict")
      }
      let judgeMilliseconds = judgeStarted.milliseconds()
      var phases = Phases(
        ready: readyMilliseconds, observe: observeMilliseconds, judge: judgeMilliseconds)
      if !alreadyCharged {
        budget.chargeDollars(verdict.usage.dollars)
        totalCost += verdict.usage.dollars
      }

      // ── ROUTE ────────────────────────────────────────────────────
      if let routed = await route(
        verdict: verdict, candidates: candidates, since: started
      ) {
        return routed
      }

      // Rung 0 named a step other than the one this iteration is holding, so
      // begin again rather than acting on a plan step that is no longer
      // current. See `applyRecovery`.
      if rewoundForRetry {
        rewoundForRetry = false
        continue
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
          action, verdict: verdict, planStep: planStep, since: started,
          stepStarted: stepStarted, phases: phases
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
        let focused = await source.focused(among: candidates.elements)
      {
        // A keystroke goes where focus is, not where a model guessed — on both
        // tiers. This is the same element ADR 0008 says `enter` must be
        // classified against.
        //
        // The browser tier had no answer here, so `Enter` after `type` went
        // through selection by name — and the name had just changed to the text
        // that was typed. Measured: a message sat composed and unsent because
        // nothing on screen was called `Message` any more.
        element = focused
        Log.info("pressKey targets the focused element: \(element.label)")
      } else if let exact = candidates.uniqueMatch(named: planStep.target) {
        // The plan named the app's own label and exactly one element carries
        // it. See `CandidateSet.uniqueMatch(named:)` — this is not the model
        // being overridden, it is a question with one answer not being asked.
        element = exact
        Log.info("one element is named exactly \(planStep.target)")
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
      let actStarted = ContinuousClock.now
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
      phases.act = actStarted.milliseconds()
      let settleStarted = ContinuousClock.now
      if executionResult.dispatched { await settle(from: screenNow, after: action) }
      phases.settle = settleStarted.milliseconds()
      // Where a step's seconds went. Every one of these is a decision someone
      // made, and the only way to argue about them is to see them.
      Log.info(phases.line(step: stepIndex))

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

  /// Starts the judgement the *next* step will need, while this one is still
  /// waiting out its quiet window.
  ///
  /// **The wait and the judgement were strictly sequential and neither needed
  /// the other.** A navigation pays a 1.2 s stillness guarantee and then a Jev
  /// call of about 600 ms, and for the whole of that first 1.2 s nothing is
  /// using the network. Running them together costs nothing and is never
  /// slower: the verdict is used only if the screen's `shape()` is identical
  /// when the window closes, and otherwise it is dropped and the step judges
  /// again exactly as it always did.
  ///
  /// Being wrong costs one Jev call — about $0.00005 — and no wall-clock time
  /// at all, because that call ran inside a wait that was happening anyway.
  /// It is charged either way, because it was really spent.
  ///
  /// The context is the *next* step's, and every piece of it is already known
  /// here: `record` has not run yet, so `planIndex` still points at the step
  /// that is finishing, and `before` is what it is about to store as the next
  /// step's `screenBefore`.
  private func beginSpeculation(
    after lastAction: Action, screenBefore: String, screenNow: String,
    candidates: CandidateSet
  ) {
    let next = planIndex + 1
    guard plan.steps.indices.contains(next) else { return }
    let context = StepContext(
      task: task,
      planStep: PlanStepDTO(plan.steps[next]),
      lastAction: ActionDTO(lastAction),
      screenBefore: screenBefore,
      screenNow: screenNow,
      recentHistory: Array(
        (history + [lastAction.summary]).suffix(Constants.Jev.historyWindow)),
      candidates: candidates.criteria,
      taskContext: taskContext
    )
    speculationIndex = next
    speculationShape = candidates.shape()
    speculationTask = Task { [weak self] in
      await self?.judgeAhead(context) ?? nil
    }
  }

  /// Runs a speculative judgement and charges what it cost, used or not.
  private func judgeAhead(_ context: StepContext) async -> StepVerdict? {
    do {
      let verdict = try await jev.step(
        context, budgetRemaining: Constants.Budget.stepTimeout)
      budget.chargeDollars(verdict.usage.dollars)
      totalCost += verdict.usage.dollars
      return verdict
    } catch {
      // A speculative failure is not a step failure. The step will ask again.
      Log.debug("the judgement started during settle did not land: \(error)")
      return nil
    }
  }

  private func clearSpeculation() {
    speculationIndex = nil
    speculationShape = nil
    speculationTask = nil
  }

  /// Where one step's milliseconds went.
  ///
  /// **The step that most needed this was the one path that did not have it.**
  /// The timing line lived only on the targeted branch, and `navigate` is
  /// targetless — so the action that replaces the whole screen and pays the
  /// longest settle in the system was invisible in the log. A three-step run
  /// printed two timing lines, and the missing one was 6.9 s of a 12.5 s run.
  struct Phases {
    let ready: Int
    let observe: Int
    let judge: Int
    var act = 0
    var settle = 0

    func line(step: Int) -> String {
      "step \(step) timing: ready=\(ready)ms observe=\(observe)ms "
        + "judge=\(judge)ms act=\(act)ms settle=\(settle)ms"
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
    stepStarted: ContinuousClock.Instant,
    phases: Phases
  ) async -> LoopResult? {
    var phases = phases
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

    let actStarted = ContinuousClock.now
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
    phases.act = actStarted.milliseconds()

    // **The steps that need this most were the ones not getting it.** Settling
    // lived only on the targeted path, and `navigate` and `openApp` are
    // targetless — so the two actions that replace the entire screen were the
    // two that were judged immediately, before anything had arrived. Instagram
    // was read at 157 nodes with no links and `readyState: loading`, and the
    // next step escalated with "no candidates to choose from".
    let settleStarted = ContinuousClock.now
    if executionResult.dispatched { await settle(from: screenBefore, after: action) }
    phases.settle = settleStarted.milliseconds()
    Log.info(phases.line(step: stepIndex))

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
  /// Waits for the screen to change, and then to stop changing.
  ///
  /// **An application is not finished when the call returns.** A click
  /// dispatches in microseconds; the redraw it causes happens on the app's own
  /// run loop. Reading the tree before that gives back the screen as it was —
  /// so Jev compares two identical descriptions, reports `unchanged`, and the
  /// ladder retries a step that had already worked. On a control that toggles,
  /// the retry undoes it. Measured on WhatsApp: clicking Search opened the
  /// panel on every run, and every run then read `unchanged ≈ 0.91`.
  ///
  /// The change is the signal. This waited for stillness instead — ten
  /// identical polls, 1.5s minimum, whether or not anything had happened —
  /// because `before` was taken as a parameter and then never read. Comparing
  /// against it is what the comment here claimed for three commits and the
  /// code never did, and it is worth about 4.7s of every 7s step.
  ///
  /// Three rules, in order of how much they are trusted:
  ///   * A page that says it is still loading is never settled.
  ///   * Nothing has changed after `noChangeTimeout` — stop waiting and let
  ///     the verification questions call it what it is.
  ///   * It changed, and has now held still. Done.
  /// Waits while the screen says it is still arriving.
  ///
  /// Only readiness — not stability. Nothing has been done yet, so there is no
  /// change to wait for; the only question is whether what is on screen is
  /// finished. A source that cannot answer is not asked, so the accessibility
  /// tier pays nothing for this.
  ///
  /// - Parameter kind: what this step is about to do. **You do not need a page
  ///   to be ready in order to leave it.** `navigate` and `openApp` replace the
  ///   screen outright, so waiting for the current one to finish arriving buys
  ///   nothing and is paid before every navigation — measured at `ready=649ms`
  ///   on the first step of an x.com run, spent watching a page the very next
  ///   action threw away. X keeps a `role="progressbar"` in its document
  ///   permanently, so that wait was the full `busyGrace` every time.
  private func waitUntilReady(before kind: ActionKind) async {
    guard kind != .navigate, kind != .openApp else { return }
    guard source.reportsReadiness else { return }
    // A site just navigated to gets the load budget. A page the agent has
    // already been working in gets a fraction of it: it is loaded, and what
    // is spinning on it is a widget.
    // **A resume is not an arrival.** `lastAction` lives only in memory, so
    // every resumed run starts with it nil and claimed the full page-load
    // budget for a page that had been loaded for minutes. On any site with a
    // permanent spinner — X always has one — that is the whole 4s, every
    // resume, measured as ready=4041ms. `history` *is* restored, so it is the
    // honest test of whether anything has happened yet: no last action and no
    // history is a genuinely cold start, no last action with history is a
    // resume in the middle of a task.
    let arriving = lastAction.map { $0.kind == .navigate || $0.kind == .openApp }
      ?? history.isEmpty
    let deadline = ContinuousClock.now.advanced(
      by: min(
        settleTimeout,
        arriving
          ? Constants.Execution.readyTimeout : Constants.Execution.readyTimeoutMidTask))
    // A spinner on an otherwise finished document is worth this much and no
    // more — see `Constants.Execution.busyGrace`.
    let busyDeadline = ContinuousClock.now.advanced(by: Constants.Execution.busyGrace)
    _ = try? await source.observe()
    while ContinuousClock.now < deadline {
      let readiness = await source.readiness()
      let spinning = readiness.hasPrefix(Self.busyMarker)
      if readiness != "loading", !spinning || ContinuousClock.now >= busyDeadline { return }
      try? await Task.sleep(for: Constants.Execution.settlePollInterval)
      _ = try? await source.observe()
    }
    Log.debug("the page still reports itself unfinished; going ahead anyway")
  }

  /// How `ElementSource.readiness()` prefixes a count when the document is
  /// finished but the page still has a busy marker on it.
  private static let busyMarker = "busy:"

  /// - Parameter before: the screen as it was before `action` ran. It is also,
  ///   at both call sites, exactly what `record` stores as the *next* step's
  ///   `screenBefore` — which is what lets a judgement be started from in here.
  private func settle(from before: String, after action: Action) async {
    let kind = action.kind
    let arriving = (kind == .navigate || kind == .openApp)
    /// How long the screen has to hold still before this returns.
    ///
    /// **Stated as a duration rather than a number of polls.** A poll count
    /// only means "this long" at one particular sampling rate, so the two were
    /// impossible to change independently: looking more often to notice
    /// stillness sooner also silently shortened the guarantee it was there to
    /// provide. Measured on x.com, the candidate list stopped changing at
    /// t=1655 ms and the step did not return until t=2869 ms — the page had
    /// arrived and the loop was counting to eight at 170 ms a turn.
    let quiet =
      arriving ? Constants.Execution.navigationQuiet : Constants.Execution.actionQuiet
    let started = ContinuousClock.now
    let deadline = started.advanced(
      by: arriving
        ? settleTimeout : min(settleTimeout, Constants.Execution.actionSettleTimeout))
    let quietDeadline = started.advanced(by: Constants.Execution.noChangeTimeout)
    /// The **shape** of the previous poll — what could be acted on, not what
    /// it said. See `CandidateSet.shape()`: a label that ticks is not a page
    /// still arriving, and comparing text meant a timeline with a video on it
    /// could never be still.
    var previous: String?
    /// The node count from the previous poll, kept apart from the element
    /// fingerprint so the two can be judged on their own terms.
    var previousNodes: Int?
    /// When the screen was first seen to repeat. `nil` whenever it last moved.
    var stillSince: ContinuousClock.Instant?
    // **Nothing to compare against is not evidence that nothing happened.** On
    // the first step there is no previous screen, so the change gate has no
    // signal — and treating "same as nothing" as "unchanged" made a navigation
    // give up 1.2s in, on X's splash logo, and report a page with no
    // candidates on it. With no `before`, only the stability rule applies, and
    // an empty screen never satisfies it.
    var changed = before.isEmpty

    // **Look first, sleep second.** The poll used to open with its interval,
    // so every settle in the system paid one before it had looked at anything
    // — including the ones where the action had already landed and the screen
    // was done. It also delayed noticing that the screen had *changed*, which
    // is what starts the clock on everything else here.
    while true {
      // **A failed observation here means "not yet", not "give up".** During a
      // navigation the document is being replaced, so the snapshot script has
      // nothing to run against and throws — and returning on that turned the
      // whole settle into a single failed poll. The next step then observed a
      // page that had not finished arriving and escalated with "no candidates
      // to choose from", on a page that had twelve of them a moment later.
      guard let elements = try? await source.observe(),
        let reduced = try? CandidateFilter.reduce(elements)
      else {
        guard ContinuousClock.now < deadline else { break }
        try? await Task.sleep(for: Constants.Execution.settlePollInterval)
        continue
      }
      // Two different questions, asked of two different renderings. Whether
      // the screen has *changed since the action* is about content, so it
      // reads the labels. Whether it has *stopped changing* is about the set
      // of available actions, so it does not.
      let described = reduced.describe()
      let shape = reduced.shape()
      // The element list *and* how finished the page claims to be. A shell with
      // a navigation rail on it is stable at twelve elements while the content
      // the step needs is still being built — see `ElementSource.readiness()`.
      let readiness = await source.readiness()
      if readiness == "loading" {
        previous = nil
        previousNodes = nil
        stillSince = nil
        guard ContinuousClock.now < deadline else { break }
        try? await Task.sleep(for: Constants.Execution.settlePollInterval)
        continue
      }
      // **A spinner does not reset stability.** It used to, and on a page that
      // keeps one — X's composer leaves its character-counter progressbar in
      // place from the first keystroke onward — that meant no poll was ever
      // stable and every step after a type ran to its ceiling.
      // The document is complete; what is left is the page's own opinion of
      // itself, and the element list is the better witness.
      let measured =
        readiness.hasPrefix(Self.busyMarker)
        ? String(readiness.dropFirst(Self.busyMarker.count)) : readiness

      if !changed {
        if described != before {
          changed = true
        } else if ContinuousClock.now >= quietDeadline {
          return
        }
      }

      // **A screen with nothing on it is never "settled".** A page still
      // painting its skeleton is stable at empty — Instagram reported 157
      // nodes, zero links, zero buttons, twice in a row, and that counted as
      // settled. The next step escalated with "no candidates to choose from"
      // against a page that was still arriving.
      // `now` carries the readiness marker and the node count, so it is never
      // empty and this asked nothing at all. X's home timeline shows its logo
      // on a black page for several seconds with `readyState: complete` and no
      // actionable element on it; three identical polls of that counted as
      // settled, and the step that followed escalated with "no candidates to
      // choose from" against a page that had not started yet.
      // **Still building, as distinct from merely alive.** Requiring the node
      // count to repeat exactly meant a page that streams could never be
      // still, so every step on a feed ran to the full timeout. Growth is the
      // question worth asking instead — see
      // `Constants.Execution.settleGrowthFactor`.
      let nodes = Int(measured)
      var growing = false
      if let nodes, let previousNodes {
        growing = Double(nodes) > Double(previousNodes) * Constants.Execution.settleGrowthFactor
      }

      if !reduced.isEmpty, shape == previous, !growing {
        let since = stillSince ?? ContinuousClock.now
        stillSince = since
        Log.debug(
          "settle poll t=\(started.milliseconds())ms still=\(since.milliseconds())ms "
            + "of \(quiet) nodes=\(measured) changed=\(changed)")
        // **The window is dead time, and so is the judgement that follows it.**
        // Once the screen has held still for half of what it owes, the rest of
        // the wait is long enough to hide a Jev call inside — measured at
        // ~600 ms against a window of 1.2 s. Half, rather than immediately,
        // because the first stillness on a page that is still arriving is
        // usually a shell between bursts: x.com reaches one at t=368 ms and
        // then moves four more times. Waiting out half the window first makes
        // the guess cheap to be wrong about and usually right.
        if arriving, speculationIndex == nil,
          ContinuousClock.now - since >= quiet / 2
        {
          beginSpeculation(
            after: action, screenBefore: before, screenNow: described, candidates: reduced)
        }
        if changed, ContinuousClock.now - since >= quiet { return }
      } else {
        Log.debug(
          "settle poll t=\(started.milliseconds())ms RESET nodes=\(measured) "
            + "changed=\(changed) growing=\(growing)")
        stillSince = nil
      }
      previous = shape
      previousNodes = nodes
      guard ContinuousClock.now < deadline else { break }
      try? await Task.sleep(for: Constants.Execution.settlePollInterval)
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

  /// One last look, after the plan runs out.
  ///
  /// **The final action of a plan was never verified.** Verification of step N
  /// arrives inside step N+1's batch, and when the plan ends there is no N+1 —
  /// so the loop returned `needs_plan` from the top of the next iteration
  /// having never once looked at the screen its last action produced. A send
  /// that worked and a send that pressed the wrong button returned the
  /// identical status and the identical reason.
  ///
  /// That put the host in an impossible position, because this project also
  /// tells it never to report success on the strength of a command exiting 0.
  /// Reported from a real session: *"The binary gave no verdict on whether the
  /// send worked, so I did not take it on faith"* — and the host went and read
  /// the page over a raw websocket to find out. The evidence existed; the
  /// binary simply never asked for it.
  ///
  /// So it asks. One observation, one batched call, about the action that has
  /// no successor. `candidates` is deliberately empty: nothing is being
  /// selected here, and an empty option set is what keeps Jev from being handed
  /// a choice it was not asked to make.
  ///
  /// A failure to read or judge is reported as the exhaustion it always was,
  /// rather than as a verdict nobody obtained.
  private func verifyLastStep(since started: ContinuousClock.Instant) async -> LoopResult {
    let exhausted = "plan exhausted at step \(planIndex)"
    // Nothing was dispatched, so there is nothing to verify and the old answer
    // is the whole answer.
    guard let lastAction, plan.steps.indices.contains(lastPlanIndex) else {
      return result(.needsPlan, since: started, reason: exhausted)
    }

    // No `waitUntilReady` here. `settle` has just run for this very action and
    // its whole job is to wait out the screen it produced; asking again would
    // pay the readiness budget a second time for one screen.
    guard let elements = try? await source.observe(),
      let screenNow = try? CandidateFilter.reduce(elements).describe()
    else {
      return result(
        .needsPlan, since: started,
        reason: "\(exhausted); the screen could not be read to verify it")
    }

    guard
      let verdict = try? await jev.step(
        StepContext(
          task: task,
          planStep: PlanStepDTO(plan.steps[lastPlanIndex]),
          lastAction: ActionDTO(lastAction),
          screenBefore: screenBefore,
          screenNow: screenNow,
          recentHistory: Array(history.suffix(Constants.Jev.historyWindow)),
          candidates: [:],
          taskContext: taskContext
        ),
        budgetRemaining: Constants.Budget.stepTimeout
      )
    else {
      return result(
        .needsPlan, since: started,
        reason: "\(exhausted); it could not be judged")
    }
    budget.chargeDollars(verdict.usage.dollars)
    totalCost += verdict.usage.dollars

    if verdict.taskDone >= Constants.Jev.taskDone {
      return result(.completed, since: started, reason: "task_done \(fmt(verdict.taskDone))")
    }

    // **A low `task_done` after every step dispatched is not a route problem.**
    // The question it answers is whether the screen *shows* the task complete,
    // and for a publish that is a different question from whether it worked:
    // measured on Facebook, a post that had gone up scored 0.02, because the
    // feed the agent lands on shows neither the post nor its text. Calling
    // that `needs_plan` told the host to write more steps for work already
    // done, and it is what sent one host off to read the page over a raw
    // websocket to find out the truth.
    if steps.last?.result.dispatched == true {
      // **Whether the action took effect is a different question from whether
      // the end state is on screen, and only the second one is unanswerable
      // after a publish.** `progressed` answers the first, and routing on
      // `task_done` alone was throwing it away — so a post that went up and a
      // post that missed its button came back identical. They are not: a
      // publish that worked closes its composer, and one that missed leaves it
      // open. Measured on the Facebook publish that did work: task_done 0.17
      // against progressed 0.59.
      if verdict.progressed >= Constants.Jev.progressed {
        return result(
          .unverified, since: started,
          reason: "the last step took effect (progressed \(fmt(verdict.progressed))) "
            + "but the screen does not show the task done "
            + "(task_done \(fmt(verdict.taskDone)))")
      }
      // Dispatched, and the screen did not move. That is the failure the
      // `unverified` answer must not be allowed to hide.
      return result(
        .needsPlan, since: started,
        reason: "\(exhausted); the last step dispatched and changed nothing "
          + "(progressed \(fmt(verdict.progressed)) task_done \(fmt(verdict.taskDone)))")
    }

    // Nothing landed, so the route really is the problem.
    return result(
      .needsPlan, since: started,
      reason: "\(exhausted); task_done \(fmt(verdict.taskDone)) "
        + "progressed \(fmt(verdict.progressed))")
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
      // `lastPlanIndex` — NOT the step the loop had moved on to.
      //
      // **Rewinding the index was not enough, and quietly did the wrong step
      // twice.** `planStep` is read at the top of the iteration, so returning
      // `nil` here ran the step the loop had *already* moved on to; `record`
      // then advanced from the rewound index and landed on that same step
      // again. Asking to redo the click typed the message twice instead —
      // observed as "hello world from open-agenthello world from open-agent"
      // in the composer, from a plan with one `type` in it.
      //
      // The verdict in hand chose a target for the step being abandoned, so it
      // cannot be reused for a different one. The iteration starts over, which
      // costs one more judgement and spends it on the right step.
      Log.info("ladder rung 0: retrying plan step \(lastPlanIndex) — \(reason)")
      planIndex = max(0, lastPlanIndex)
      rewoundForRetry = true
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
