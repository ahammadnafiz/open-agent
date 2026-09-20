import Foundation
import Testing

@testable import Harness

@Suite("AgentLoop routing")
struct AgentLoopTests {

  @Test("task_done above its threshold completes")
  func taskDoneCompletes() async {
    let judge = ScriptedJudge([Make.verdict(taskDone: Constants.Jev.taskDone)])
    let result = await Make.loop(plan: Make.plan([.click]), judge: judge).run()
    #expect(result.status == .completed)
    #expect(result.reason.contains("task_done"))
  }

  /// **`blocked` is terminal.** Retrying a login wall produces another login
  /// wall; the agent has no credential to offer and no amount of retrying
  /// invents one.
  @Test("blocked is terminal and nothing is executed")
  func blockedIsTerminal() async {
    let judge = ScriptedJudge([Make.verdict(blocked: Constants.Jev.blocked)])
    let executor = RecordingExecutor()
    let result = await Make.loop(
      plan: Make.plan([.click, .click, .click]), judge: judge, executor: executor
    ).run()

    #expect(result.status == .blocked)
    #expect(await executor.executed.isEmpty)
  }

  /// The five verification questions compare `screen_before` to `screen_now`.
  /// On step 0 there is no last action, so they answer about nothing — and a
  /// low `progressed` there must not send a brand-new task to the ladder.
  @Test("step 0 does not route on verification questions")
  func stepZeroIgnoresVerification() async {
    let judge = ScriptedJudge([Make.verdict(progressed: 0.01, unchanged: 0.99)])
    let executor = RecordingExecutor()
    let result = await Make.loop(
      plan: Make.plan([.click]), judge: judge, executor: executor
    ).run()

    // The single plan step ran — once, not retried. The verdict's progressed
    // is 0.01, so the exhaustion check reads it as a step that dispatched and
    // moved nothing, which is a route problem rather than an unverifiable one.
    #expect(await executor.executed.count == 1)
    #expect(result.status == .needsPlan)
  }

  /// SPEC.md § S2 — verification catches an induced failure on the *next*
  /// step rather than continuing blindly.
  @Test("a no-op is caught on the following step and retried")
  func noOpIsCaughtAndRetried() async {
    let judge = ScriptedJudge([
      Make.verdict(),  // step 0 acts
      Make.verdict(progressed: 0.03, unchanged: 0.84),  // it did nothing
      Make.verdict(),  // the retry acts
      Make.verdict(taskDone: 0.95),  // and that worked
    ])
    let executor = RecordingExecutor()
    let result = await Make.loop(
      plan: Make.plan([.click, .click]), judge: judge, executor: executor
    ).run()

    #expect(result.status == .completed)
    // Rung 0 retried the plan step rather than advancing past it: the same
    // step twice, and not a third action from running the plan on past it.
    #expect(await executor.executed.count == 2)
  }

  /// The branch measurement justified. `progressed` low **and** `unchanged`
  /// low means the screen moved and did not help — an unexpected dialog, the
  /// wrong account, a redirect. Retrying reproduces it exactly, so the ladder
  /// jumps straight to rung 2.
  @Test("a screen that moved without helping skips the retry rung")
  func movedButUnhelpfulSkipsRetry() async {
    let judge = ScriptedJudge([
      Make.verdict(),
      Make.verdict(progressed: 0.03, unchanged: 0.04),
    ])
    let result = await Make.loop(plan: Make.plan([.click, .click]), judge: judge).run()
    #expect(result.status == .needsPlan, "rung 2 replans instead of retrying")
  }

  @Test("looping escalates rather than continuing")
  func loopingEscalates() async {
    let judge = ScriptedJudge([
      Make.verdict(),
      Make.verdict(looping: Constants.Jev.looping),
    ])
    let result = await Make.loop(plan: Make.plan([.click, .click]), judge: judge).run()
    #expect(result.status == .needsEyes)
    #expect(result.reason.contains("looping"))
  }

  /// Right screen, wrong instance. Every other verification question answers
  /// correctly while the agent composes from the wrong account.
  @Test("wrong_context routes to recovery when the task named an instance")
  func wrongContextRoutes() async {
    let judge = ScriptedJudge([
      Make.verdict(),
      Make.verdict(wrongContext: Constants.Jev.wrongContext),
    ])
    let result = await Make.loop(
      plan: Make.plan([.click, .click]), judge: judge,
      taskContext: "the company mailbox"
    ).run()
    #expect(result.reason.contains("wrong_context"))
  }

  @Test("wrong_context is never asked when the task names no instance")
  func wrongContextNotAskedWithoutContext() async {
    let judge = ScriptedJudge([Make.verdict(taskDone: 0.95)])
    _ = await Make.loop(plan: Make.plan([.click]), judge: judge, taskContext: "").run()
    let context = await judge.lastContext
    #expect(context?.namesAnInstance == false)
  }

  // MARK: - The selection gate

  @Test("low sufficient escalates to needs_eyes")
  func lowSufficientEscalates() async {
    let judge = ScriptedJudge([Make.verdict(sufficient: 0.41)])
    let result = await Make.loop(plan: Make.plan([.click]), judge: judge).run()
    #expect(result.status == .needsEyes)
    #expect(result.reason.contains("sufficient"))
    #expect(result.candidates?.isEmpty == false)
  }

  @Test("low confidence escalates to needs_eyes")
  func lowConfidenceEscalates() async {
    let judge = ScriptedJudge([
      Make.verdict(confidence: 0.46, probabilities: ["e0": 0.46, "e1": 0.29])
    ])
    let result = await Make.loop(plan: Make.plan([.click]), judge: judge).run()
    #expect(result.status == .needsEyes)
    #expect(result.reason.contains("confidence"))
  }

  /// Two candidates at 0.48 and 0.47 is a coin flip that `confidence` reports
  /// as unremarkable. The margin check is the only thing that catches it.
  @Test("a thin margin escalates even when confidence passes")
  func thinMarginEscalates() async {
    let judge = ScriptedJudge([
      Make.verdict(confidence: 0.95, probabilities: ["e0": 0.48, "e1": 0.47])
    ])
    let result = await Make.loop(plan: Make.plan([.click]), judge: judge).run()
    #expect(result.status == .needsEyes)
    #expect(result.reason.contains("margin"))
  }

  /// The id comes from a model response. An out-of-range id must escalate,
  /// not trap.
  @Test("an unresolvable candidate id escalates")
  func unresolvableIDEscalates() async {
    let judge = ScriptedJudge([Make.verdict(choice: "e99", probabilities: ["e99": 0.99])])
    let result = await Make.loop(plan: Make.plan([.click]), judge: judge).run()
    #expect(result.status == .needsEyes)
  }

  // MARK: - The safety gate

  /// SPEC.md § S3 — no irreversible action executes without approval.
  @Test("an irreversible action is confirmed before it executes")
  func irreversibleIsConfirmed() async {
    let judge = ScriptedJudge([Make.verdict(taskDone: 0.05)])
    let hud = RecordingHUD(approve: true)
    let executor = RecordingExecutor()
    _ = await Make.loop(
      plan: Make.plan([.send]), judge: judge, executor: executor, hud: hud
    ).run()

    let confirmations = await hud.confirmations
    #expect(confirmations.count == 1)
    #expect(confirmations.first?.becauseIrreversible == true)
    #expect(await executor.executed.count == 1)
  }

  @Test("declining at the sheet stops the task without executing")
  func declineStopsTheTask() async {
    let judge = ScriptedJudge([Make.verdict()])
    let hud = RecordingHUD(approve: false)
    let executor = RecordingExecutor()
    let result = await Make.loop(
      plan: Make.plan([.delete]), judge: judge, executor: executor, hud: hud
    ).run()

    #expect(result.status == .failed)
    #expect(result.reason.contains("declined"))
    #expect(await executor.executed.isEmpty, "nothing runs after a refusal")
  }

  /// The advisory gate decides whether to **ask**, never whether to allow.
  @Test("advisory risk confirms an otherwise reversible action")
  func advisoryRiskConfirms() async {
    let judge = ScriptedJudge([Make.verdict(riskOutbound: Constants.Jev.riskConfirm)])
    let hud = RecordingHUD(approve: true)
    _ = await Make.loop(plan: Make.plan([.click]), judge: judge, hud: hud).run()

    let confirmations = await hud.confirmations
    #expect(confirmations.count == 1)
    #expect(confirmations.first?.becauseIrreversible == false)
  }

  @Test("a reversible, low-risk action is not confirmed")
  func reversibleIsNotConfirmed() async {
    let judge = ScriptedJudge([Make.verdict()])
    let hud = RecordingHUD(approve: true)
    _ = await Make.loop(plan: Make.plan([.click]), judge: judge, hud: hud).run()
    #expect(await hud.confirmations.isEmpty)
  }

  /// The headless bridge refuses every confirmation. A no-UI default that
  /// auto-approved would be a hole in the only boundary that cannot be
  /// recovered from.
  @Test("the headless bridge never approves")
  func headlessNeverApproves() async {
    let judge = ScriptedJudge([Make.verdict()])
    let executor = RecordingExecutor()
    let result = await Make.loop(
      plan: Make.plan([.publish]), judge: judge, executor: executor, hud: HeadlessHUD()
    ).run()
    #expect(result.status == .failed)
    #expect(await executor.executed.isEmpty)
  }

  // MARK: - Budgets — SPEC.md § S4

  @Test("the step ceiling stops a task that never converges")
  func stepCeilingStops() async {
    let judge = ScriptedJudge([Make.verdict()])
    let longPlan = Make.plan(Array(repeating: .click, count: 100))
    let result = await Make.loop(
      plan: longPlan, judge: judge, budget: Budget(steps: 3)
    ).run()

    #expect(result.status == .budgetExhausted)
    #expect(result.reason.contains("steps"))
    #expect(result.step == 3)
  }

  @Test("the dollar ceiling stops a task")
  func dollarCeilingStops() async {
    let judge = ScriptedJudge([Make.verdict()])
    let result = await Make.loop(
      plan: Make.plan(Array(repeating: .click, count: 100)),
      judge: judge,
      budget: Budget(dollars: 0.00005)  // ~1 step at measured rates
    ).run()
    #expect(result.status == .budgetExhausted)
    #expect(result.reason.contains("dollars"))
  }

  @Test("the machine-time ceiling stops a task")
  func machineTimeCeilingStops() async {
    let judge = ScriptedJudge([Make.verdict()])
    let result = await Make.loop(
      plan: Make.plan(Array(repeating: .click, count: 100)),
      judge: judge,
      budget: Budget(machineTime: .nanoseconds(1))
    ).run()
    #expect(result.status == .budgetExhausted)
  }

  // MARK: - Failure surfaces

  @Test("a perception failure surfaces rather than looping")
  func perceptionFailureSurfaces() async {
    let loop = AgentLoop(
      task: "t", plan: Make.plan([.click]), sessionID: "s", pid: 0,
      source: FailingSource(error: PerceptionError.accessibilityNotTrusted),
      jev: ScriptedJudge([Make.verdict()]),
      executors: RecordingExecutor(), hud: HeadlessHUD(),
      settleTimeout: .zero
    )
    let result = await loop.run()
    #expect(result.status == .failed)
    #expect(result.reason.contains("perception"))
  }

  /// The executor reports mechanics. A dispatch failure is recorded and the
  /// loop continues — only the next Jev batch knows whether the task moved.
  @Test("an execution failure is recorded, not thrown away")
  func executionFailureIsRecorded() async {
    let judge = ScriptedJudge([Make.verdict(), Make.verdict(taskDone: 0.95)])
    let executor = RecordingExecutor()
    await executor.setShouldFail(true)
    let result = await Make.loop(
      plan: Make.plan([.click, .click]), judge: judge, executor: executor
    ).run()
    #expect(result.steps.first?.result.dispatched == false)
  }

  @Test("history is carried into the Jev state, windowed")
  func historyIsWindowed() async {
    let judge = ScriptedJudge([Make.verdict()])
    _ = await Make.loop(
      plan: Make.plan(Array(repeating: .click, count: 10)), judge: judge,
      budget: Budget(steps: 8)
    ).run()
    let context = await judge.lastContext
    #expect((context?.recentHistory.count ?? 99) <= Constants.Jev.historyWindow)
  }
}
