import Foundation
import Testing

@testable import Harness

/// Defects found by review, each with the test that would have caught it.
///
/// These are kept together deliberately. A regression test whose name explains
/// *what broke* is worth more six months from now than one filed under the
/// feature it happens to touch.
@Suite("Review regressions")
struct RegressionTests {

  // MARK: - Typing reported success and typed nothing

  /// `AXUIElementSetAttributeValue` returning `.success` does not mean the
  /// value changed. Measured on WhatsApp's search field: the write returned
  /// success, the field stayed empty, the step reported `dispatched=true`, and
  /// the search results the next step needed never appeared.
  ///
  /// The keystroke fallback existed directly below it and was unreachable,
  /// because it was guarded on a return code that lies.
  @Test("a write that changed nothing falls back to keystrokes")
  func ignoredWriteFallsBack() {
    #expect(AXExecutor.writeWasIgnored("Zisan", before: "", after: ""))
    #expect(AXExecutor.writeWasIgnored("Zisan", before: "old", after: "old"))
    #expect(AXExecutor.writeWasIgnored("Zisan", before: nil, after: nil))
  }

  /// The happy path must not double-type.
  @Test("a write that landed does not fall back")
  func landedWriteDoesNotFallBack() {
    #expect(!AXExecutor.writeWasIgnored("Zisan", before: "", after: "Zisan"))
    #expect(!AXExecutor.writeWasIgnored("Zisan", before: "Zisan", after: "Zisan"))
  }

  /// **The narrow test matters more than the broad one.** A field that
  /// transformed the text, or took part of it, has done something — typing it
  /// again on top would duplicate it, which is a worse failure than the one
  /// being fixed and one the next step's verification would have to untangle.
  @Test(
    "a field that transformed the text is left alone",
    arguments: [("+1 555", "5551234567"), ("ZISAN", ""), ("Zis", "")])
  func transformedValueIsNotRetyped(after: String, before: String) {
    #expect(!AXExecutor.writeWasIgnored("Zisan", before: before, after: after))
  }

  // MARK: - WhatsApp was unaddressable by its own name

  /// The window server reports WhatsApp's owner name as `U+200E WhatsApp` — a
  /// LEFT-TO-RIGHT MARK carried through from the localized name, which its
  /// `CFBundleName` does not have. `pid(forApp:)` matched exactly, so
  /// `--app WhatsApp` reported "WhatsApp is not running" while WhatsApp sat on
  /// screen with a standard window.
  ///
  /// Measured on this machine: `e2 80 8e 57 68 61 74 73 41 70 70`. The
  /// character is invisible in a title, a screenshot and a log line, so nothing
  /// short of a hexdump distinguishes the two strings.
  @Test("an app name with a bidi mark matches the plain name")
  func bidiMarkedAppNameMatches() {
    let asReported = "\u{200E}WhatsApp"
    #expect(asReported != "WhatsApp")  // the bug, in one line
    #expect(WindowGuard.normalized(appName: asReported) == "whatsapp")
    #expect(
      WindowGuard.normalized(appName: asReported)
        == WindowGuard.normalized(appName: "WhatsApp"))
  }

  /// The other format characters an app name can pick up. None of them carry
  /// identity — they tell a text renderer what to do.
  @Test(
    "format characters never change identity",
    arguments: [
      "\u{200E}WhatsApp", "WhatsApp\u{200F}", "What\u{200D}sApp",
      "\u{FEFF}WhatsApp", "  WhatsApp  ", "whatsapp",
    ])
  func formatCharactersStripped(variant: String) {
    #expect(WindowGuard.normalized(appName: variant) == "whatsapp")
  }

  /// Normalising must not collapse names that are genuinely different, or
  /// `--app Mail` would start resolving to Mailbox.
  @Test("different apps stay different")
  func distinctNamesStayDistinct() {
    #expect(WindowGuard.normalized(appName: "Mail") != WindowGuard.normalized(appName: "Mailbox"))
    #expect(WindowGuard.normalized(appName: "Notes") != WindowGuard.normalized(appName: "Note"))
  }

  // MARK: - A plan could not open the app it planned to open

  /// `AXSource` resolves a pid in `init`, and the executable built it *before*
  /// the loop ran. So `open-agent run … --app WhatsApp` with a plan whose first
  /// step was `openApp` exited 2 with "WhatsApp is not running" — the step that
  /// would have started it was never reached.
  ///
  /// Found by running the first real task on this binary. It is the same shape
  /// as the defect `PlanStep.needsTarget` fixed inside the loop: a step naming
  /// no on-screen element still has to happen somewhere.
  @Test("a plan whose next step opens the app says which app to open")
  func launchTargetNamesTheApp() {
    let plan = Plan(steps: [
      PlanStep(kind: .openApp, target: "WhatsApp", payload: "WhatsApp"),
      PlanStep(kind: .click, target: "the search field", payload: nil),
    ])
    #expect(plan.launchTarget(atPlanIndex: 0, appName: "WhatsApp") == "WhatsApp")
  }

  /// **This is the safety half, and it is the more important one.** An agent
  /// that launched an application nobody mentioned would be inventing actions.
  @Test("a plan that does not open an app launches nothing")
  func noLaunchWithoutAPlannedOpen() {
    let plan = Plan(steps: [
      PlanStep(kind: .click, target: "the search field", payload: nil),
      PlanStep(kind: .openApp, target: "Mail", payload: "Mail"),
    ])
    #expect(plan.launchTarget(atPlanIndex: 0, appName: "WhatsApp") == nil)
  }

  /// A plan that opens an app at step two has not asked for it at step one.
  /// Only the step that is actually next counts, or `resume` after an unrelated
  /// failure would relaunch something the user had since quit.
  @Test("only the step that is next counts")
  func onlyTheNextStepCounts() {
    let plan = Plan(steps: [
      PlanStep(kind: .openApp, target: "WhatsApp", payload: "WhatsApp"),
      PlanStep(kind: .click, target: "the search field", payload: nil),
    ])
    #expect(plan.launchTarget(atPlanIndex: 1, appName: "WhatsApp") == nil)
  }

  /// An exhausted plan has nothing left to ask for, and an out-of-range index
  /// must not read backwards into a step already taken.
  @Test("an exhausted or out-of-range plan launches nothing")
  func exhaustedPlanLaunchesNothing() {
    let plan = Plan(steps: [PlanStep(kind: .openApp, target: "WhatsApp", payload: "WhatsApp")])
    #expect(plan.launchTarget(atPlanIndex: 1, appName: "WhatsApp") == nil)
    #expect(plan.launchTarget(atPlanIndex: 99, appName: "WhatsApp") == nil)
    #expect(Plan(steps: []).launchTarget(atPlanIndex: 0, appName: "WhatsApp") == nil)
  }

  /// `openApp` carries its app in the payload, but a plan that named it only in
  /// `target` should still work rather than launching an app called "".
  @Test("a payload-less openApp falls back to the session's app")
  func payloadlessOpenAppFallsBack() {
    let plan = Plan(steps: [PlanStep(kind: .openApp, target: "WhatsApp", payload: nil)])
    #expect(plan.launchTarget(atPlanIndex: 0, appName: "WhatsApp") == "WhatsApp")
    #expect(plan.launchTarget(atPlanIndex: 0, appName: "") == nil)
  }

  // MARK: - Budget survived only one invocation

  /// `LoopState.budget` was a computed `Budget()`, so it was never encoded and
  /// every `resume` handed the task a fresh 40 steps / 90 s / $0.25.
  ///
  /// SPEC.md § S4: *"No task exceeds 40 steps, 90 seconds of machine time,
  /// 3 vision escalations, 2 replans, or $0.25."* Ceilings that reset on resume
  /// are not ceilings — a task that escalated repeatedly was unbounded.
  @Test("the budget survives a round trip through LoopState")
  func budgetSurvivesResume() throws {
    var budget = Budget()
    budget.chargeStep()
    budget.chargeStep()
    budget.chargeDollars(0.1)
    budget.chargeEscalation()

    let state = AgentLoop.LoopState(
      budget: budget, history: ["click Post"], planIndex: 3, stepIndex: 3,
      screenBefore: "<AXButton> Post", totalCost: 0.1
    )
    let round = try JSONDecoder().decode(
      AgentLoop.LoopState.self, from: try JSONEncoder().encode(state)
    )

    #expect(round.budget.stepsRemaining == Constants.Budget.maxSteps - 2)
    #expect(round.budget.escalationsRemaining == Constants.Budget.maxEscalations - 1)
    #expect(abs(round.budget.dollarsRemaining - (Constants.Budget.maxDollars - 0.1)) < 1e-9)
    #expect(
      round.budget.stepsRemaining != Constants.Budget.maxSteps, "a fresh budget means it reset")
  }

  /// A loop resumed from spent state must not get its ceilings back.
  @Test("a resumed loop inherits the spent budget")
  func resumedLoopInheritsBudget() async {
    var spent = Budget(steps: 2)
    spent.chargeStep()
    spent.chargeStep()

    let loop = AgentLoop(
      task: "t", plan: Make.plan(Array(repeating: .click, count: 20)),
      sessionID: "s", pid: 0, source: FakeSource(elements: [Make.element()]),
      jev: ScriptedJudge([Make.verdict()]), executors: RecordingExecutor(),
      hud: HeadlessHUD(),
      resumeFrom: AgentLoop.LoopState(
        budget: spent, history: [], planIndex: 0, stepIndex: 0,
        screenBefore: "", totalCost: 0
      )
    )
    let result = await loop.run()
    #expect(result.status == .budgetExhausted)
  }

  // MARK: - Escalation and replan ceilings were unreachable

  /// `Budget.exhausted()` omitted both, so `BudgetCeiling.escalations` and
  /// `.replans` could never be returned, though SPEC.md § S4 names them.
  @Test("an overrun escalation ceiling is reported")
  func escalationCeilingReported() {
    var budget = Budget(escalations: 0)
    #expect(budget.exhausted() == nil, "at zero it is spent, not overrun")
    budget.chargeEscalation()
    #expect(budget.exhausted() == .escalations)
  }

  @Test("an overrun replan ceiling is reported")
  func replanCeilingReported() {
    var budget = Budget(replans: 0)
    budget.chargeReplan()
    #expect(budget.exhausted() == .replans)
  }

  // MARK: - resume --eyes was validated then discarded

  /// The host looked at a marked screenshot and answered with a number, and the
  /// loop logged it and threw it away. `needs_eyes` is the primary callback —
  /// SPEC.md:229 — so this was the escalation path not working at all.
  @Test("a host-selected mark is the element that gets acted on")
  func eyesAnswerSelectsTheElement() async {
    let elements = [
      Make.element(label: "Home", path: [0]),
      Make.element(label: "Archive", path: [1]),
      Make.element(label: "Compose", path: [2]),
    ]
    let executor = RecordingExecutor()
    // A verdict that would NOT pass the gate on its own, so anything executed
    // can only have come from the mark.
    let judge = ScriptedJudge([
      Make.verdict(choice: "e0", confidence: 0.20, probabilities: ["e0": 0.34, "e1": 0.33])
    ])
    let loop = AgentLoop(
      task: "t", plan: Make.plan([.click]), sessionID: "s", pid: 0,
      source: FakeSource(elements: elements), jev: judge, executors: executor,
      hud: HeadlessHUD(),
      pendingEyes: EyesAnswer(index: 3, label: "the compose icon")
    )
    _ = await loop.run()

    let executed = await executor.executed
    #expect(executed.count == 1)
    // Marks are drawn 1-based, so mark 3 is candidate index 2.
    #expect(executed.first?.target?.label == "Compose")
  }

  /// The label is not decoration. 74.2% of pressable elements are icon-only, so
  /// without it `LabelDenylist` has nothing to match on for exactly those
  /// targets — ADR 0007 §3. It must be able to raise the classification.
  @Test("the host's vision label reaches the safety gate")
  func eyesLabelReachesTheDenylist() async {
    // The element's own label is innocuous; only the host's label is dangerous.
    let icon = Make.element(label: "toolbar item 4", path: [0])
    let hud = RecordingHUD(approve: false)
    let loop = AgentLoop(
      task: "t", plan: Make.plan([.click]), sessionID: "s", pid: 0,
      source: FakeSource(elements: [icon]),
      jev: ScriptedJudge([Make.verdict(choice: "e0", probabilities: ["e0": 0.99])]),
      executors: RecordingExecutor(), hud: hud,
      pendingEyes: EyesAnswer(index: 1, label: "the paper-aeroplane send icon")
    )
    let result = await loop.run()

    #expect(await hud.confirmations.count == 1, "the vision label must raise the classification")
    #expect(await hud.confirmations.first?.becauseIrreversible == true)
    #expect(result.status == .failed, "declined")
  }

  @Test("a mark that is not on the current screen asks for a new route")
  func staleMarkReplans() async {
    let loop = AgentLoop(
      task: "t", plan: Make.plan([.click]), sessionID: "s", pid: 0,
      source: FakeSource(elements: [Make.element()]),
      jev: ScriptedJudge([Make.verdict()]), executors: RecordingExecutor(),
      hud: HeadlessHUD(),
      pendingEyes: EyesAnswer(index: 99, label: "gone")
    )
    let result = await loop.run()
    #expect(result.status == .needsPlan)
  }

  // MARK: - openApp could never execute

  /// The loop built an `Action` only after resolving a candidate, so
  /// `target: nil` was unreachable and `openApp` — the first step of the S1
  /// reference task — threw every time.
  @Test("a targetless step executes without selection")
  func targetlessStepExecutes() async {
    let executor = RecordingExecutor()
    let loop = AgentLoop(
      task: "open Mail and reply",
      plan: Plan(steps: [
        PlanStep(kind: .openApp, target: "Mail", payload: "Mail")
      ]),
      sessionID: "s", pid: 0,
      // No candidates at all: a targetless step must not need any.
      source: FakeSource(elements: []),
      jev: ScriptedJudge([Make.verdict(choice: nil)]),
      executors: executor, hud: HeadlessHUD()
    )
    _ = await loop.run()

    let executed = await executor.executed
    #expect(executed.count == 1)
    #expect(executed.first?.kind == .openApp)
    #expect(executed.first?.target == nil)
  }

  @Test("targetless kinds are exactly openApp, navigate and wait")
  func targetlessKinds() {
    for kind in ActionKind.allCases {
      let expected = [.openApp, .navigate, .wait].contains(kind)
      #expect(PlanStep.needsTarget(kind) == !expected, "\(kind.rawValue)")
    }
  }

  // MARK: - The step log dropped the verdict

  /// SPEC.md § Boundaries: *"Log every step with its verdict, its cost, and the
  /// model version that answered."* `Step` carried no verdict at all.
  @Test("every logged step carries its verdict, cost and model version")
  func stepLogIsComplete() async {
    let loop = AgentLoop(
      task: "t", plan: Make.plan([.click]), sessionID: "s", pid: 0,
      source: FakeSource(elements: [Make.element()]),
      jev: ScriptedJudge([Make.verdict(progressed: 0.91, riskOutbound: 0.33)]),
      executors: RecordingExecutor(), hud: HeadlessHUD()
    )
    let result = await loop.run()
    let step = try? #require(result.steps.first)

    #expect(step?.verdict.progressed == 0.91)
    #expect(step?.verdict.riskMax == 0.33)
    #expect(step?.modelVersion == Constants.Models.jev)
    #expect(step?.requestID == "req_test")
    #expect((step?.cost.inputTokens ?? 0) > 0)
  }

  // MARK: - The recovery ladder ignored its own constant

  /// `Constants.Recovery.retriesPerStep` had no readers — the ladder hardcoded
  /// its rung numbers. A constant in the file humans review before a release
  /// that changes nothing when edited is worse than no constant at all.
  @Test("the ladder retries exactly retriesPerStep times before escalating")
  func ladderHonoursRetryConstant() {
    var ladder = RecoveryLadder()
    // unchanged high -> a genuine no-op, so rung 0 applies
    let noOp = Make.verdict(progressed: 0.03, unchanged: 0.91)
    let budget = Budget()

    for attempt in 0..<Constants.Recovery.retriesPerStep {
      #expect(
        ladder.next(for: 0, verdict: noOp, budget: budget) == .retry,
        "retry \(attempt + 1) of \(Constants.Recovery.retriesPerStep)"
      )
    }
    #expect(ladder.next(for: 0, verdict: noOp, budget: budget) == .escalate)
  }
}
