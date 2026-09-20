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
        // The AX executor still exists: `openApp` and native fallbacks are
        // reachable from a browser task.
        axSource = try AXSource(appName: "Zen")
        pid = axSource.pid
        bidiExecutor = BiDiExecutor(client: client, source: browserSource)
      } catch {
        fail(describe(error))
      }
    } else {
      do {
        axSource = try AXSource(appName: session.appName)
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

  // MARK: - Browser session

  /// Launches the agent's browser and connects BiDi.
  ///
  /// Idempotent in the way that matters: if something is already listening on
  /// the port, `connect()` succeeds and no second browser is started. A launch
  /// that raced would leave an orphan process holding the profile lock.
  static func browserSession() async throws -> (BiDiClient, BiDiSource) {
    // `allowRestart: true` — the agent may quit a running browser to free its
    // profile. That is only acceptable because the quit is graceful, so the
    // session is saved and the tabs come back. ADR 0011.
    let handle = try await BrowserLauncher.ensureDrivable(allowRestart: true)
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
