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

  // MARK: - Invisible characters in element labels

  /// WhatsApp puts a `U+200E` LEFT-TO-RIGHT MARK on the front of every label:
  /// `‎Search`, `‎Compose message`. Nothing renders it — not a screenshot, not
  /// a log line, not a diff — so a label looks correct and compares unequal.
  ///
  /// **The dangerous half is the denylist.** It matches on this string, so a
  /// format character inside a word would carry a denylisted term straight past
  /// the check. The annoying half is that Jev reads these labels to decide
  /// which candidate a plan step names.
  @Test("format characters are stripped from labels")
  func labelsAreCleaned() {
    #expect(AXPrimitives.cleaned("\u{200E}Search") == "Search")
    #expect(AXPrimitives.cleaned("\u{200E}Compose message") == "Compose message")
    #expect(AXPrimitives.cleaned("  \u{200F}Send  ") == "Send")
    // A term hidden from the denylist by a zero-width joiner mid-word.
    #expect(AXPrimitives.cleaned("Se\u{200D}nd") == "Send")
  }

  /// Stripping must not merge labels that name different things, or the
  /// candidate list starts offering two identical-looking rows.
  @Test("cleaning does not collapse distinct labels")
  func cleaningKeepsDistinctions() {
    #expect(AXPrimitives.cleaned("Send") != AXPrimitives.cleaned("Sent"))
    #expect(AXPrimitives.cleaned("Reply") != AXPrimitives.cleaned("Reply all"))
  }

  // MARK: - The confirmation sheet is off

  /// The owner turned it off. This asserts that it is actually off, and that
  /// an irreversible step runs rather than hanging on a window nobody will
  /// answer — a sheet that never appears but is still waited on is worse than
  /// either choice.
  ///
  /// The classification is deliberately left alone: every step is still judged
  /// irreversible or not, and every verdict still reaches the log. What changed
  /// is whether the agent stops, not whether it knows.
  @Test("the sheet is off by default, and the step still runs")
  func sheetIsOffByDefault() async {
    #expect(Constants.Safety.askBeforeIrreversible == false)

    let hud = RecordingHUD(approve: false)
    let executor = RecordingExecutor()
    let loop = Make.loop(
      plan: Make.plan([.send]),
      judge: ScriptedJudge([Make.verdict(choice: "e0", probabilities: ["e0": 0.99])]),
      executor: executor, hud: hud,
      asksBeforeIrreversible: Constants.Safety.askBeforeIrreversible
    )
    _ = await loop.run()

    #expect(await hud.confirmations.isEmpty, "nothing should have been asked")
    #expect(await !executor.executed.isEmpty, "the step should still have run")
  }

  // MARK: - Keystrokes outran the application

  /// Characters were posted back to back with no gap at all, and focus was
  /// requested in the same breath as the first one.
  ///
  /// Both are races an application loses quietly: keys arriving faster than it
  /// drains its event queue are dropped, and keys posted before it has acted on
  /// the focus request go wherever focus still is. Measured on WhatsApp, that
  /// was the chat list, where "Zisan" behaved as type-select and dismissed the
  /// search panel the next step needed.
  ///
  /// Asserted rather than merely commented, because every one of these reads
  /// like a value someone could tidy to zero while making typing "faster" —
  /// and the symptom would be a step that still reports `dispatched=true`.
  @Test("synthesized input is paced, and focus is given time to land")
  func typingIsPaced() {
    #expect(Constants.Typing.keystrokeIntervalMicroseconds > 0)
    #expect(Constants.Typing.keyHoldMicroseconds > 0)
    #expect(Constants.Typing.focusTimeoutSeconds > 0)
    #expect(Constants.Typing.focusPollMicroseconds > 0)

    // A sentence must still be under a second: this is a pace, not an
    // imitation of human typing, and a task budget is 90 seconds of machine
    // time for the whole route.
    let perCharacter =
      Double(Constants.Typing.keystrokeIntervalMicroseconds + Constants.Typing.keyHoldMicroseconds)
      / 1_000_000
    #expect(perCharacter * 40 < 1.0)

    // And the focus wait must be short enough that several steps can each pay
    // it without the task's own ceiling becoming the thing that fails.
    #expect(Constants.Typing.focusTimeoutSeconds < 1.0)
  }

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
      ),
      settleTimeout: .zero
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
      pendingEyes: EyesAnswer(index: 3, label: "the compose icon"),
      settleTimeout: .zero
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
      pendingEyes: EyesAnswer(index: 1, label: "the paper-aeroplane send icon"),
      asksBeforeIrreversible: true, settleTimeout: .zero
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
      pendingEyes: EyesAnswer(index: 99, label: "gone"),
      settleTimeout: .zero
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
      executors: executor, hud: HeadlessHUD(),
      settleTimeout: .zero
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
      executors: RecordingExecutor(), hud: HeadlessHUD(),
      settleTimeout: .zero
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

  // MARK: - Enter went looking for a name that had changed

  /// **A keystroke goes where focus is, on every tier.**
  ///
  /// The focused-element short-circuit existed, and it was reached through
  /// `source as? AXSource` — so on a web page `Enter` fell through to selection
  /// by name. That is the one moment where the name cannot hold: a field's
  /// accessible name is its own value once something has been typed into it.
  /// Instagram's composer is `Message` while empty and `hiii orumoni` after,
  /// and a plan that named it when it was written no longer matches anything.
  ///
  /// Measured: a message composed, dispatched, verified — and never sent,
  /// because step 4 could not find a target called `Message`.
  @Test("enter goes where focus is, not where the plan's name points")
  func pressKeyFollowsFocusNotName() async throws {
    // The judge would pick the Send button; focus is in the composer, whose
    // name is now the text that was typed into it.
    let judge = ScriptedJudge([Make.verdict(choice: "e0")])
    let executor = RecordingExecutor()
    let composer = Make.element(label: "hiii orumoni", role: "AXTextArea", path: [1])

    _ = await Make.loop(
      plan: Make.plan([.pressKey]),
      judge: judge,
      executor: executor,
      elements: [Make.element(label: "Send", path: [0]), composer],
      focusedLabel: "hiii orumoni"
    ).run()

    let action = try #require(await executor.executed.first)
    #expect(action.target == composer.ref, "the keystroke went to the focused field")
  }

  /// A source that cannot report focus is not made to guess — it falls through
  /// to selection, which is the behaviour every non-browser, non-AX tier has.
  @Test("a source with no notion of focus still selects normally")
  func pressKeyWithoutFocusFallsBackToSelection() async throws {
    let judge = ScriptedJudge([Make.verdict(choice: "e0")])
    let executor = RecordingExecutor()
    // Deliberately not a word on the denylist: this test is about selection,
    // and a confirmation would stop the step before it could be observed.
    let chosen = Make.element(label: "Compose", path: [0])

    _ = await Make.loop(
      plan: Make.plan([.pressKey]),
      judge: judge,
      executor: executor,
      elements: [chosen, Make.element(label: "hiii orumoni", role: "AXTextArea", path: [1])],
      focusedLabel: nil
    ).run()

    let action = try #require(await executor.executed.first)
    #expect(action.target == chosen.ref)
  }

  // MARK: - Selection hesitated over the word it was given

  /// **A run stopped to ask a human to look at a screenshot of the word
  /// `Send`.** The step targeted `Send`, one element on the page was labelled
  /// `Send`, and selection came back at 0.76 — under the gate.
  ///
  /// Verification, risk and the safety gate all still run. The only thing
  /// skipped is a question with one answer.
  @Test("an exactly and uniquely named target is selected without the gate")
  func exactNameSkipsTheSelectionGate() async throws {
    // Selection is refused outright: no choice, sufficiency on the floor.
    let judge = ScriptedJudge([Make.verdict(choice: nil, sufficient: 0.10)])
    let executor = RecordingExecutor()
    let compose = Make.element(label: "Compose", path: [1])

    let result = await Make.loop(
      plan: Plan(steps: [PlanStep(kind: .click, target: "Compose", payload: nil)]),
      judge: judge,
      executor: executor,
      elements: [Make.element(label: "Home", path: [0]), compose]
    ).run()

    let action = try #require(await executor.executed.first)
    #expect(action.target == compose.ref)
    #expect(result.status != .needsEyes, "nothing to look at — it was named")
  }

  /// And when the name is ambiguous, the model still decides. The shortcut is
  /// for questions with one answer, not for skipping the hard ones.
  @Test("two elements with that name still go to selection")
  func ambiguousNameStillEscalates() async {
    let judge = ScriptedJudge([Make.verdict(choice: nil, sufficient: 0.10)])
    let executor = RecordingExecutor()

    let result = await Make.loop(
      plan: Plan(steps: [PlanStep(kind: .click, target: "Compose", payload: nil)]),
      judge: judge,
      executor: executor,
      elements: [Make.element(label: "Compose", path: [0]), Make.element(label: "Compose", path: [1])]
    ).run()

    #expect(await executor.executed.isEmpty)
    #expect(result.status == .needsEyes)
  }

  // MARK: - The wait that was never told what it was waiting for

  /// **`settle(from:)` took the previous screen as a parameter and never read
  /// it.** So instead of waiting for the screen to change it waited for the
  /// screen to hold still — ten identical polls, 1.5s minimum, whether or not
  /// anything had happened, and the full ten-second ceiling whenever a page
  /// had something moving on it. It was about 4.7s of every 7s step.
  ///
  /// A screen that never changes is a real outcome. `unchanged` is one of the
  /// five verification questions and Jev answers it in a second; waiting ten
  /// for the same information is the definition of a slow agent.
  @Test("a screen that never changes is not waited out to the ceiling")
  func settleGivesUpWhenNothingHappens() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    _ = await Make.loop(
      plan: Make.plan([.click]), judge: judge, settleTimeout: .seconds(5)
    ).run()

    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(elapsed < .seconds(3), "it was waiting for stillness, not for change")
    // And it did wait: giving up instantly would be the other bug.
    #expect(elapsed >= Constants.Execution.noChangeTimeout)
  }

  /// **A screen with nothing on it is never settled — and the check for that
  /// asked nothing.** The guard compared the whole observation string, which
  /// carries a readiness marker and a node count and is therefore never empty.
  ///
  /// X's home timeline shows its logo on a black page for several seconds,
  /// with `readyState: complete` and not one actionable element. Three
  /// identical polls of that counted as settled, the next step escalated with
  /// "no candidates to choose from", and the recovery ladder spent 55 seconds
  /// re-asking a page that had not started yet.
  @Test("a page that goes empty is waited out, not settled on")
  func settleWillNotSettleOnAnEmptyScreen() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    _ = await Make.loop(
      plan: Make.plan([.click]),
      judge: judge,
      settleTimeout: .seconds(2),
      source: ChangingSource(first: [Make.element()], then: [])
    ).run()

    let elapsed = started.duration(to: ContinuousClock.now)
    // The ceiling an ordinary action actually gets, rather than a number
    // copied out of it — those diverge the first time one is tuned.
    let ceiling = min(Duration.seconds(2), Constants.Execution.actionSettleTimeout)
    #expect(elapsed >= ceiling, "an empty page is not a finished page")
  }

  // MARK: - It acted on a page that had not finished arriving

  /// **`settle` covers the gap after an action; nothing covered the first
  /// step.** A run starting on a page that was still building was judged
  /// against a half-built screen, and the pointer set off toward an element
  /// whose neighbours had not rendered — which is what the user saw:
  /// *"without waiting for the whole loading of the site, the cursor moved."*
  @Test("a screen that says it is still arriving is not judged yet")
  func waitsForTheScreenToArrive() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    _ = await Make.loop(
      plan: Make.plan([.click]),
      judge: judge,
      settleTimeout: .seconds(2),
      // Never finishes. The ceiling is what stops this, and it must stop it:
      // a page with a permanent spinner is still a page with a task on it.
      source: LoadingSource(elements: [Make.element()], loadingForObservations: .max)
    ).run()

    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(elapsed >= .seconds(2), "it judged a page that said it was loading")
    #expect(await judge.callCount >= 1, "and it did eventually go ahead")
  }

  /// A page that is ready costs one observation, not a wait. The gate is for
  /// screens that are arriving, not a tax on screens that have arrived.
  @Test("a screen that has arrived is not waited on")
  func readyScreensAreNotDelayed() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    _ = await Make.loop(
      plan: Make.plan([.click]),
      judge: judge,
      settleTimeout: .seconds(5),
      source: LoadingSource(elements: [Make.element()], loadingForObservations: 0)
    ).run()

    #expect(started.duration(to: ContinuousClock.now) < .seconds(2))
  }
}

/// Two ways the loop used to spend seconds waiting for something that was
/// never going to happen.
@Suite("Waiting for what has already happened")
struct SettleAndResumeRegressionTests {

  /// **A page that streams can never repeat a node count.** Settle
  /// fingerprinted the candidate list together with `readiness()`, and
  /// `readiness()` is the DOM node count — so on any feed the fingerprint
  /// differed every poll, two consecutive identical polls never happened, and
  /// the step ran to the full `actionSettleTimeout` after the thing it was
  /// waiting for had already landed. Measured on X: settle=1582ms and
  /// settle=1662ms against a 1500ms ceiling.
  @Test("a page that keeps growing slowly still settles")
  func aStreamingPageSettles() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    let source = StreamingSource(
      before: [Make.element()],
      after: [Make.element(), Make.element(label: "Home", path: [1])])
    _ = await Make.loop(
      plan: Make.plan([.click]),
      judge: judge,
      executor: RecordingExecutor(onExecute: { await source.landed() }),
      settleTimeout: .seconds(5),
      source: source
    ).run()

    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(
      elapsed < .seconds(1),
      "settle waited out its ceiling on a page whose elements had held still")
  }

  /// **A resume is not an arrival.** `lastAction` is in-memory only, so every
  /// resumed run began with it nil and took the full page-load budget for a
  /// page that had been loaded for minutes. On a site with a permanent
  /// spinner that is the whole 4s, every resume — measured as ready=4041ms.
  @Test("a resume mid-task does not pay the page-load budget")
  func aResumeIsNotAnArrival() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    let loop = AgentLoop(
      task: "test task", taskContext: "", plan: Make.plan([.click, .click]),
      sessionID: "s_test", pid: 0,
      // Never finishes loading, so the budget is the only thing that ends the
      // wait — which makes the size of that budget the whole measurement.
      source: LoadingSource(elements: [Make.element()], loadingForObservations: .max),
      jev: judge, executors: RecordingExecutor(), hud: HeadlessHUD(),
      resumeFrom: AgentLoop.LoopState(
        history: ["click Home"], planIndex: 1, stepIndex: 1,
        screenBefore: "<button> Home", totalCost: 0),
      asksBeforeIrreversible: false,
      settleTimeout: .seconds(5)
    )
    _ = await loop.run()

    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(
      elapsed < .seconds(3.5),
      "a resume in the middle of a task waited as though the page were arriving")
  }
}

/// **A spinner that never clears is scenery.** X keeps one visible
/// progressbar on an idle, fully loaded home timeline — measured
/// `ready=complete busy=1` with nothing happening. Reporting that as
/// `loading` made every settle poll reset, so stability could never
/// accumulate and every step paid its full ceiling; `waitUntilReady` paid its
/// full budget for the same reason.
@Suite("A spinner is not a loading page")
struct BusyMarkerRegressionTests {

  @Test("a page that is always busy still settles")
  func anAlwaysBusyPageSettles() async {
    let judge = ScriptedJudge([Make.verdict()])
    let started = ContinuousClock.now

    let source = SpinningSource(
      before: [Make.element()],
      after: [Make.element(), Make.element(label: "Home", path: [1])])
    _ = await Make.loop(
      plan: Make.plan([.click]),
      judge: judge,
      executor: RecordingExecutor(onExecute: { await source.landed() }),
      settleTimeout: .seconds(5),
      source: source
    ).run()

    let elapsed = started.duration(to: ContinuousClock.now)
    #expect(
      elapsed < .seconds(1.6),
      "a permanent spinner held the step at its ceiling in both phases")
    // Twice, and both are load-bearing: one call chooses the action, and one
    // verifies it once the plan runs out. See `verifyLastStep`.
    #expect(await judge.callCount == 2, "and it still judged the page, then verified it")
  }
}


/// **The last action of a plan was never verified.** Verification of step N
/// arrives in step N+1's batch, and when the plan ends there is no N+1 — so
/// the loop reported `needs_plan` having never looked at the screen its final
/// action produced. A send that worked and a send that pressed the wrong
/// button returned the identical status and reason, which left the host no
/// in-band way to tell them apart.
@Suite("The last step gets verified too")
struct FinalVerificationTests {

  @Test("a finished plan whose last step worked reports completed")
  func aFinishedPlanCompletes() async {
    // First verdict selects the action; the second is the verification that
    // used to never happen.
    let judge = ScriptedJudge([
      Make.verdict(taskDone: 0.05),
      Make.verdict(taskDone: 0.96),
    ])

    let outcome = await Make.loop(
      plan: Make.plan([.click]), judge: judge, settleTimeout: .zero
    ).run()

    #expect(outcome.status == .completed)
    #expect(outcome.reason.contains("task_done"))
    #expect(await judge.callCount == 2, "one call to choose, one to verify")
  }

  @Test("a finished plan whose last step did nothing says what it saw")
  func anUnverifiedPlanSaysWhy() async {
    let judge = ScriptedJudge([Make.verdict(progressed: 0.11, taskDone: 0.05)])

    let outcome = await Make.loop(
      plan: Make.plan([.click]), judge: judge, settleTimeout: .zero
    ).run()

    #expect(outcome.status == .needsPlan)
    // Still not a failure — the route may simply be short — but the reason now
    // carries the evidence instead of only "the steps ran out".
    #expect(outcome.reason.contains("task_done"), "the reason was \(outcome.reason)")
    #expect(outcome.reason.contains("progressed"), "the reason was \(outcome.reason)")
  }

  /// Nothing dispatched means nothing to verify, and asking anyway spends a
  /// call to learn that the screen never changed.
  @Test("an empty plan is not verified")
  func anEmptyPlanIsNotVerified() async {
    let judge = ScriptedJudge([Make.verdict()])

    let outcome = await Make.loop(
      plan: Make.plan([]), judge: judge, settleTimeout: .zero
    ).run()

    #expect(outcome.status == .needsPlan)
    #expect(await judge.callCount == 0)
  }
}
