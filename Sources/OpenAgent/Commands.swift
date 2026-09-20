import AppKit
import Foundation
import Harness

/// The verbs, end to end.
///
/// Each one prints exactly one JSON object and returns. Nothing here writes
/// prose to stdout.
enum Commands {

  // MARK: - run

  @MainActor
  static func run(_ options: CLI.Options) async {
    guard let task = options.task, !task.isEmpty else {
      fail("run requires a task: open-agent run \"<task>\"")
    }

    // A plan is the host's job. Without one there is nothing to execute, and
    // `needs_plan` is precisely the status that says so — the host reads it,
    // plans, and calls back. That is one round trip, not an error.
    guard let planPath = options.planPath else {
      let session = Session(
        id: Session.newID(), task: task, taskContext: options.taskContext,
        plan: Plan(steps: []), appName: options.app ?? "", browser: options.browser,
        state: .init(history: [], planIndex: 0, stepIndex: 0, screenBefore: "", totalCost: 0),
        waitingFor: .needsPlan, candidates: nil
      )
      try? session.save()
      emit(
        HostResponse(
          session: session.id, status: .needsPlan, step: 0,
          elapsedMilliseconds: 0, costUSD: 0,
          reason: "no plan supplied — send steps with `resume \(session.id) --plan plan.json`"
        )
      )
      return
    }

    let plan: Plan
    do {
      plan = try JSONDecoder().decode(
        Plan.self, from: try Data(contentsOf: URL(fileURLWithPath: planPath)))
    } catch {
      fail("could not read --plan \(planPath): \(error)")
    }

    let appName = options.app ?? frontmostAppName()
    var session = Session(
      id: Session.newID(), task: task, taskContext: options.taskContext,
      plan: plan, appName: appName, browser: options.browser,
      state: .init(history: [], planIndex: 0, stepIndex: 0, screenBefore: "", totalCost: 0),
      waitingFor: nil, candidates: nil
    )
    try? session.save()
    await drive(&session, resumeState: nil)
  }

  // MARK: - resume

  @MainActor
  static func resume(_ options: CLI.Options) async {
    guard let id = options.session else { fail("resume requires a session id") }
    guard var session = try? Session.load(id) else {
      fail("unknown session \(id)")
    }

    if let planPath = options.planPath {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: planPath)),
        let replacement = try? JSONDecoder().decode(Plan.self, from: data)
      else { fail("could not read --plan \(planPath)") }
      // Replacement steps continue from where the loop stopped, rather
      // than restarting the task: the steps already taken really happened.
      session.plan = Plan(
        steps: Array(session.plan.steps.prefix(session.state.planIndex)) + replacement.steps)
    }

    var pendingEyes: EyesAnswer?
    if let eyes = options.eyes {
      // The host answers with an INDEX, never a coordinate. `none` means
      // the target is genuinely absent, which is a real answer and not a
      // failure to answer.
      if eyes == "none" {
        emit(
          HostResponse(
            session: session.id, status: .needsPlan, step: session.state.stepIndex,
            elapsedMilliseconds: 0, costUSD: session.state.totalCost,
            history: session.state.history,
            reason: "the host reports the target is not on screen — the route needs to change"
          )
        )
        session.waitingFor = .needsPlan
        try? session.save()
        return
      }
      guard let index = Int(eyes) else {
        fail("--eyes takes an index or `none`, got \(eyes)")
      }
      // The chosen mark overrides selection for exactly one step. The screen is
      // still re-observed and re-judged in the same batch, because it may have
      // moved since the screenshot was taken.
      pendingEyes = EyesAnswer(
        index: index,
        label: options.labelWasProvided ? options.label : nil
      )
      Log.info("resuming with host-selected mark \(index)")
    }

    await drive(&session, resumeState: session.state, pendingEyes: pendingEyes)
  }

  // MARK: - observe

  static func runHeadless(_ options: CLI.Options) async {
    switch options.verb {
    case .observe: await observe(options)
    case .act: await act(options)
    default: fail("unreachable verb")
    }
  }

  static func observe(_ options: CLI.Options) async {
    if options.browser {
      await observeBrowser()
      return
    }
    let appName = options.app ?? frontmostAppName()
    do {
      let source = try AXSource(appName: appName)
      let candidates = try CandidateFilter.reduce(try await source.observe())
      emit(
        HostResponse(
          session: "-", status: .completed, step: 0,
          elapsedMilliseconds: 0, costUSD: 0,
          candidates: candidates.criteria,
          reason: "observed \(candidates.count) candidates in \(appName)"
        )
      )
    } catch {
      fail(describe(error))
    }
  }

  static func observeBrowser() async {
    do {
      let (client, source) = try await browserSession()
      let candidates = try CandidateFilter.reduce(try await source.observe())
      await client.close()
      emit(
        HostResponse(
          session: "-", status: .completed, step: 0,
          elapsedMilliseconds: 0, costUSD: 0,
          candidates: candidates.criteria,
          reason: "observed \(candidates.count) candidates in the browser"
        )
      )
    } catch {
      fail(describe(error))
    }
  }

  // MARK: - act

  static func act(_ options: CLI.Options) async {
    guard let kindRaw = options.kind, let kind = ActionKind(rawValue: kindRaw) else {
      fail("--kind must be one of: \(ActionKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    guard let targetID = options.target else { fail("--target is required, e.g. --target e17") }

    let appName = options.app ?? frontmostAppName()
    do {
      let source = try AXSource(appName: appName)
      let candidates = try CandidateFilter.reduce(try await source.observe())
      guard let element = candidates.element(forID: targetID) else {
        fail("no candidate \(targetID) — `observe` first; ids are only valid for one observation")
      }

      let action = Action(
        kind: kind, target: element.ref, payload: options.payload,
        rationale: "single step from the CLI"
      )

      // The gate runs here exactly as it does inside the loop. `act` is a
      // debugging verb; it is NOT a way around the confirmation boundary.
      let effective = Irreversibility.classify(action, target: element)
      if Irreversibility.requiresConfirmation(effective, riskMax: 0) {
        fail(
          "\(action.summary) classifies as \(effective) and needs a human at the sheet — "
            + "run it through `open-agent run` where the sheet can be shown"
        )
      }

      let executor = AXExecutor(source: source)
      let result = try await executor.execute(action)
      emit(
        HostResponse(
          session: options.session ?? "-", status: .completed, step: 0,
          elapsedMilliseconds: 0, costUSD: 0,
          reason: "dispatched \(action.summary) (dispatched=\(result.dispatched))"
        )
      )
    } catch {
      fail(describe(error))
    }
  }

  // MARK: - Driving the loop

  @MainActor
  private static func drive(
    _ session: inout Session,
    resumeState: AgentLoop.LoopState?,
    pendingEyes: EyesAnswer? = nil
  ) async {
    let jev: JevClient
    do {
      jev = try JevClient()
    } catch {
      fail(Credentials.missingKeyGuidance)
    }

    // The target world is a property of the step, not of the task — a task can
    // cross the boundary. `--browser` decides which source the loop starts on.
    let source: any ElementSource
    let pid: pid_t
    var bidiClient: BiDiClient?
    var bidiExecutor: BiDiExecutor?
    let axSource: AXSource

    if session.browser {
      do {
        let (client, browserSource) = try await browserSession()
        bidiClient = client
        source = browserSource
        // Work in our own tab, from the first observation onward. Reusing the
        // one this task opened earlier when there is one, so a run plus two
        // resumes is one tab and not three.
        await client.adoptTab(session.browserContext)
        session.browserContext = try await client.openAgentTab()
        do {
          // The AX executor still exists: `openApp` and native fallbacks are
          // reachable from a browser task.
          axSource = try await raisedSource(appName: "Zen", launchIfMissing: nil)
        } catch {
          // **Ending the session is not optional on the failure path.** A
          // process that exits between `connect` and `close` leaves the browser
          // holding its one WebDriver session for a client that no longer
          // exists, and the next run has to restart the browser to clear it —
          // which is a window closing in the user's face, caused by an error
          // that had nothing to do with them. This exact leak is what made
          // every browser invocation restart Zen.
          await client.close()
          fail(describe(error))
        }
        pid = axSource.pid
        bidiExecutor = BiDiExecutor(client: client, source: browserSource)
      } catch {
        await bidiClient?.close()
        fail(describe(error))
      }
    } else {
      do {
        axSource = try await nativeSource(for: session)
      } catch {
        fail(describe(error))
      }
      source = axSource
      pid = axSource.pid
    }

    let executors = ExecutorRegistry(
      ax: AXExecutor(source: axSource),
      captured: CapturedExecutor(
        pid: pid, appName: session.appName,
        // Tier 3/4 is not wired to a live capture yet, so there is no
        // frame to hash — and `CapturedExecutor` refuses to act without
        // one rather than guessing. ADR 0007 makes that a precondition,
        // not a nicety.
        frameHash: { nil }
      ),
      bidi: bidiExecutor
    )

    let loop = AgentLoop(
      task: session.task, taskContext: session.taskContext, plan: session.plan,
      sessionID: session.id, pid: pid, source: source, jev: jev,
      executors: executors, hud: AppHUD(),
      capture: ScreenCapture(), artifactsDirectory: Session.directory,
      resumeFrom: resumeState,
      pendingEyes: pendingEyes
    )

    let result = await loop.run()
    await bidiClient?.close()
    session.state = await loop.state()
    session.waitingFor = result.status
    session.candidates = result.candidates
    try? session.save()

    emit(
      HostResponse(
        session: session.id,
        status: result.status,
        step: result.step,
        elapsedMilliseconds: Int(result.elapsed.inSeconds * 1000),
        costUSD: result.costUSD,
        screenshot: result.screenshot,
        candidates: result.candidates,
        history: result.history,
        reason: result.reason
      )
    )
  }

  // MARK: - Native session

  /// Builds the native source, launching the app first when the plan's next
  /// step is what would have launched it.
  ///
  /// `AXSource` resolves a pid in `init`, so an app that is not running is a
  /// hard failure *before the loop starts*. That made a plan whose first step
  /// is `openApp` impossible to run — and "open WhatsApp and message someone"
  /// is the shape of most real tasks, so the failure was not an edge case.
  ///
  /// It is the same class of bug `PlanStep.needsTarget` fixed inside the loop:
  /// a step that names no on-screen element still has to happen somewhere, and
  /// perception is not somewhere it can happen.
  ///
  /// **The launch is not an action the plan did not ask for.** It is the step
  /// the plan already declared, hoisted because perception cannot be
  /// constructed without it — and only ever that step, because an agent that
  /// launched an app nobody mentioned would be inventing actions, which is the
  /// thing the whole safety model rests on it not doing. The loop still
  /// executes the step; `open -a` on a running app only brings it forward, so
  /// it appears once in the audit log with its own verdict, exactly as if it
  /// had run in order.
  private static func nativeSource(for session: Session) async throws -> AXSource {
    try await raisedSource(
      appName: session.appName,
      launchIfMissing: session.plan.launchTarget(
        atPlanIndex: session.state.planIndex, appName: session.appName)
    )
  }

  /// An `AXSource` for an app that may not be reachable from here yet.
  ///
  /// Every caller needs this, not just the one that first hit it. A browser
  /// task builds an AX source for Zen so that `openApp` and native fallbacks
  /// stay available, and it failed with "Zen is not running" against a browser
  /// the launcher had just started — because Zen was not frontmost and
  /// `CGWindowList` reports only the current Space.
  ///
  /// - Parameter launchIfMissing: the app to start when nothing is running.
  ///   `nil` means raise-only: refuse rather than launch something nobody
  ///   asked for.
  private static func raisedSource(
    appName: String, launchIfMissing: String?
  ) async throws -> AXSource {
    if let source = try? AXSource(appName: appName) { return source }

    // Running, but not reachable from here — on another Space, or closed to
    // the Dock. Bringing forward the app the caller named is not an action the
    // agent invented; it is the app it was told to drive, and is about to.
    //
    // `open -a` rather than `NSRunningApplication.activate()`: an app closed to
    // the Dock has no window to raise, and only a reopen makes it draw one.
    // Measured: WhatsApp sits in the Dock with zero windows, which `activate()`
    // leaves exactly as it found it.
    //
    // A failure here falls through rather than throwing, because the plan may
    // still carry an `openApp` that knows a name this did not.
    if runningApp(named: appName) != nil {
      try? AXExecutor.launch(app: appName)
      if let source = try await awaitWindow(for: appName) { return source }
    }

    // Not running at all. Launching is a bigger step than raising, so it
    // happens only when the plan itself asked for it — an agent that launched
    // an application nobody mentioned would be inventing actions, which is the
    // thing the whole safety model rests on it not doing.
    guard let name = launchIfMissing else {
      throw PerceptionError.appNotRunning(appName)
    }

    Log.info("launching \(name) — the plan opens it, and perception cannot start before it does")
    try AXExecutor.launch(app: name)
    if let source = try await awaitWindow(for: appName) { return source }
    throw PerceptionError.appNotRunning(appName)
  }

  /// The running application with this name, whichever Space it is on.
  ///
  /// **`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` reports only the
  /// current Space**, so an app on another desktop is indistinguishable from
  /// one that was never launched. The host agent runs from a terminal, which is
  /// almost never on the same Space as the app being driven — so every
  /// `needs_eyes` callback failed on the resume with "is not running", about an
  /// app that was plainly running and had already been driven for three steps.
  ///
  /// It answers one question only — *may* this app be brought forward, or would
  /// that be launching something nobody asked for. The bringing forward is done
  /// with `open -a`, which also works on an app closed to the Dock.
  ///
  /// `.regular` only: a menu-bar agent or background helper sharing a name with
  /// a real app is not the thing the caller meant to drive.
  private static func runningApp(named name: String) -> NSRunningApplication? {
    let wanted = WindowGuard.normalized(appName: name)
    return NSWorkspace.shared.runningApplications.first {
      $0.activationPolicy == .regular
        && WindowGuard.normalized(appName: $0.localizedName ?? "") == wanted
    }
  }

  /// Polls until the app has a window this process can actually see.
  ///
  /// A window, not just a pid. An app that has launched or been raised but
  /// drawn nothing observes as *empty*, which reads as "that screen has nothing
  /// on it" rather than "it is still coming up" — the distinction Q6 exists
  /// for. Polling rather than sleeping, because a cold start of a large app is
  /// seconds and raising one that is already open is instant.
  private static func awaitWindow(for appName: String) async throws -> AXSource? {
    let deadline = ContinuousClock.now.advanced(by: Constants.AX.launchTimeout)
    while ContinuousClock.now < deadline {
      if let source = try? AXSource(appName: appName),
        WindowGuard.hasVisibleWindow(pid: source.pid)
      {
        return source
      }
      try await Task.sleep(for: Constants.AX.launchPollInterval)
    }
    return nil
  }

  // MARK: - Browser session

  /// Launches the agent's browser and connects BiDi.
  ///
  /// Idempotent in the way that matters: if something is already listening on
  /// the port, `connect()` succeeds and no second browser is started. A launch
  /// that raced would leave an orphan process holding the profile lock.
  static func browserSession() async throws -> (BiDiClient, BiDiSource) {
    do {
      return try await attachBrowser(forceRestart: false)
    } catch BiDiError.sessionHeldElsewhere {
      // The browser is up and listening, and holding its one WebDriver session
      // for a client that has since exited. Nothing on this side can adopt that
      // session or end it, and waiting is waiting for nothing — the session
      // dies with the process, so the process has to go.
      //
      // Restarting is the same graceful quit ADR 0011 already does: the tabs
      // come back. It happens once, and only on this specific diagnosis.
      Log.info("the browser holds a session for a client that is gone — restarting it once")
      return try await attachBrowser(forceRestart: true)
    }
  }

  private static func attachBrowser(forceRestart: Bool) async throws -> (BiDiClient, BiDiSource) {
    // `allowRestart: true` — the agent may quit a running browser to free its
    // profile. That is only acceptable because the quit is graceful, so the
    // session is saved and the tabs come back. ADR 0011.
    let handle = try await BrowserLauncher.ensureDrivable(
      allowRestart: true, forceRestart: forceRestart)
    if handle.restartedExistingBrowser {
      Log.info("restarted the browser to attach to profile \(handle.profile)")
    }
    let client = BiDiClient(port: handle.port)
    try await client.connect()
    return (client, BiDiSource(client: client))
  }

  // MARK: - Output

  /// Exactly one JSON object to stdout. Exit 0 — the status carries the
  /// outcome, and a non-zero code is reserved for a malformed invocation.
  static func emit(_ response: HostResponse) {
    guard let line = try? response.encoded() else {
      fail("could not encode the response")
    }
    print(line)
  }

  /// A malformed invocation. JSON on stdout so the host still does not have to
  /// parse prose, and a non-zero exit so it can tell this apart from a status.
  static func fail(_ reason: String) -> Never {
    let escaped =
      reason
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
    print("{\"error\":\"\(escaped)\"}")
    exit(2)
  }

  /// Turns a typed error into the one sentence a human needs to fix it.
  static func describe(_ error: any Error) -> String {
    switch error {
    case PerceptionError.accessibilityNotTrusted:
      return "Accessibility is not granted to this binary. The grant is per-binary, so a "
        + "freshly built executable is untrusted even in a granted terminal. "
        + "Add it in System Settings → Privacy & Security → Accessibility."
    case PerceptionError.appNotRunning(let name):
      return "\(name) is not running, or has no on-screen window."
    case PerceptionError.windowNotOnScreen(let name):
      return "\(name) has no window on the current Space. A minimized or off-Space window "
        + "observes as empty rather than as an error, so this stops instead of guessing."
    case PerceptionError.noWindow(let name):
      return "Could not resolve a window for \(name) after \(Constants.AX.windowRetries) attempts."
    case CandidateError.tooManyCandidates(let count):
      return "\(count) candidates exceeds the \(Constants.Jev.maxCandidates) ceiling."
    case ExecutionError.focusNotAccepted:
      return "The application never accepted focus on that element, so nothing was typed. "
        + "Typing anyway would have sent the keys wherever focus actually is."
    case CandidateError.noCandidates:
      return "Nothing labelled and actionable is on screen."
    case JevError.missingAPIKey:
      return Credentials.missingKeyGuidance
    default:
      return "\(error)"
    }
  }

  /// The frontmost application that is not this one.
  ///
  /// `NSWorkspace` lives in the executable, never in `Harness` — the library
  /// stays headless.
  static func frontmostAppName() -> String {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    if let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier != selfPID,
      let name = front.localizedName
    {
      return name
    }
    return "Finder"
  }
}
