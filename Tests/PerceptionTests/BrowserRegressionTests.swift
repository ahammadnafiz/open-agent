import Foundation
import Testing

@testable import Harness

/// A scripted BiDi socket. Records everything sent, so what the client does on
/// teardown is assertable without a browser.
actor FakeBiDiTransport: BiDiTransport {
  private var replies: [String]
  private(set) var sent: [String] = []
  private(set) var cancelled = false

  init(replies: [String]) { self.replies = replies }

  nonisolated func cancel() {
    Task { await self.markCancelled() }
  }
  private func markCancelled() { cancelled = true }

  func send(_ text: String) async throws { sent.append(text) }

  func receive() async throws -> String {
    guard !replies.isEmpty else { throw BiDiError.disconnected }
    return replies.removeFirst()
  }

  /// The methods the client sent, in order.
  func methods() -> [String] {
    sent.compactMap { line in
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return object["method"] as? String
    }
  }
}

private func ok(_ id: Int, _ result: String = "{}") -> String {
  #"{"type":"success","id":\#(id),"result":\#(result)}"#
}

private func err(_ id: Int, _ message: String) -> String {
  #"{"type":"error","id":\#(id),"error":"unknown error","message":"\#(message)"}"#
}

private let oneContext = #"{"contexts":[{"context":"ctx-1","url":"about:blank"}]}"#

@Suite("The agent's own tab — regression")
struct AgentTabRegressionTests {

  /// **Navigating took over the page the user was reading.** `getTree` returns
  /// the tabs that are open; driving one of them replaces whatever is in it,
  /// in the user's own browser, with no way back but history. Observed: an
  /// Instagram login page appeared where their page had been.
  ///
  /// So when nothing open is on that site, a tab is opened for the task.
  @Test("navigate opens a tab when nothing open is on that site")
  func navigateOpensItsOwnTab() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1),  // session.new
      ok(2, #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#),
      ok(3, #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#),
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name — not ours
      // window.open, answering with the WindowProxy for the named tab
      ok(5, #"{"result":{"type":"window","value":{"context":"agent-tab"}}}"#),
      ok(6),  // browsingContext.activate
      ok(7),  // browsingContext.navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    #expect(try await client.context() == "users-tab", "attaches to what is open")

    try await client.navigate(to: "https://instagram.com/")
    #expect(try await client.context() == "agent-tab", "and works in its own tab after")
  }

  /// **A browser already showing Instagram got a second Instagram, every run.**
  ///
  /// The rule that kept the agent out of the user's tab had no exception for
  /// the tab that is already on the site the task is about — which is the one
  /// case where taking it over is not taking anything over. They are signed in
  /// there, they are looking at it, and they said so twice: *"i already open
  /// instagram, but it again open new tab"*.
  ///
  /// Matched on host, not on URL: their tab sits on a thread while the task
  /// navigates to the inbox, and requiring equality would open a second one.
  @Test("a tab already on that site is used instead of a second one")
  func navigateReusesTheOpenTab() async throws {
    let open = #"{"contexts":[{"context":"insta-tab","url":"https://www.instagram.com/direct/t/17/"}]}"#
    let transport = FakeBiDiTransport(replies: [
      ok(1),  // session.new
      ok(2, open),  // resolveContext
      ok(3, open),  // tab(for:)
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name — theirs
      ok(5),  // browsingContext.activate
      ok(6),  // browsingContext.navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://www.instagram.com/direct/inbox/")

    #expect(try await client.context() == "insta-tab")
    let opened = await transport.sent.filter { $0.contains("window.open") }
    #expect(opened.isEmpty, "nothing was opened — their tab was already the right one")
  }

  /// **The tab is found by name, not remembered by id.** Persisting the id was
  /// tried first and cannot work: BiDi context ids are not stable across
  /// sessions, so the id one process writes is not the id the next one sees for
  /// the same tab. Measured — the browser's tab count climbed with every
  /// invocation while `getTree` never contained the remembered id.
  @Test("the tab is opened by name so separate processes share it")
  func tabIsNamed() {
    #expect(BiDiClient.tabName.contains("open_agent"))
    #expect(BiDiClient.tabName.count > 8, "a name a page might also use would be a collision")
  }

  /// **Containers are separate cookie jars.** A tab the agent opens inherits
  /// the container of whatever it was opened from, so the agent's own x.com tab
  /// — opened from an Instagram tab in another workspace — was served the login
  /// page while the user's X tab, two tabs away, was signed in. The run
  /// reported `blocked` against an account that was logged in the whole time.
  ///
  /// Both tabs are on the host. The one the agent did not create is the one
  /// with the session in it.
  @Test("the user's tab on that host wins over the agent's own")
  func theirTabBeatsOurs() async throws {
    let tree = #"""
      {"contexts":[{"context":"ours","url":"https://x.com/"},
                   {"context":"theirs","url":"https://x.com/home"}]}
      """#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, tree),
      ok(3, tree),  // tab(for:)
      ok(4, #"{"result":{"type":"string","value":"__open_agent_tab"}}"#),  // ours
      ok(5, #"{"result":{"type":"string","value":""}}"#),  // theirs
      ok(6),  // activate
      ok(7),  // navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://x.com/home")

    #expect(try await client.context() == "theirs")
  }

  /// **`window.open(url, name)` only finds tabs the opener is familiar with.**
  ///
  /// Named targeting searches the opener's browsing context group, so a process
  /// that attached to an unrelated tab could not see its own tab and opened
  /// another one. Measured: a resume of a run that was working in Instagram
  /// attached to a GitHub tab, opened a third blank tab, and reported an empty
  /// screen one keypress short of sending the message.
  ///
  /// So the name is scanned for across every tab instead of being looked up
  /// through an opener.
  @Test("the agent's tab is found from an unrelated tab")
  func namedTabFoundAcrossTheTree() async throws {
    let tree = #"""
      {"contexts":[{"context":"github-tab","url":"https://github.com/monzim/ecom"},
                   {"context":"agent-tab","url":"https://www.instagram.com/direct/t/17/"}]}
      """#
    let transport = FakeBiDiTransport(replies: [
      ok(1),  // session.new
      ok(2, tree),  // resolveContext picks the first loaded tab — GitHub
      ok(3, tree),  // tab(for:)
      ok(4, #"{"result":{"type":"string","value":"not-ours"}}"#),
      ok(5, #"{"result":{"type":"string","value":"__open_agent_tab"}}"#),
      ok(6),  // browsingContext.activate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    #expect(try await client.context() == "github-tab")

    // No URL: this is a resume, and the navigation it would have hinted with
    // happened in the run before.
    let tab = try await client.tab()
    #expect(tab == "agent-tab")
    let opened = await transport.sent.filter { $0.contains("window.open") }
    #expect(opened.isEmpty, "found, not opened")
  }

  /// Nothing to reuse and nowhere to go is not a reason to open a blank tab.
  /// One was opened per invocation, and the user watched them pile up.
  @Test("with nothing to reuse and no destination, no tab is opened")
  func noDestinationOpensNothing() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#),
      ok(3, #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#),
      ok(4, #"{"result":{"type":"string","value":""}}"#),
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()

    #expect(try await client.tab() == "users-tab")
    let opened = await transport.sent.filter { $0.contains("window.open") }
    #expect(opened.isEmpty)
  }

  /// Once per session, not once per navigation. A task that visits three pages
  /// is still one piece of work, and a tab per step is the other way to make a
  /// mess of someone's browser.
  @Test("a multi-step task reuses the one tab it opened")
  func oneTabPerSession() async throws {
    let after = #"""
      {"contexts":[{"context":"ctx-1","url":"about:blank"},
                   {"context":"agent-tab","url":"https://a.example/"}]}
      """#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, oneContext),
      ok(3, oneContext),  // tab(for:) — one blank tab, no host to match
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name
      ok(5, #"{"result":{"type":"window","value":{"context":"agent-tab"}}}"#),
      ok(6),  // activate
      ok(7),  // first navigate
      ok(8, after),  // tab(for:) — the tab it made is in the tree now
      ok(9),  // second navigate
      ok(10, after),
      ok(11),  // third navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://a.example/")
    try await client.navigate(to: "https://b.example/")
    try await client.navigate(to: "https://c.example/")

    let opened = await transport.sent.filter { $0.contains("window.open") }
    #expect(opened.count == 1, "one tab, not three")
  }

  /// `www.` is a spelling, not a site. Instagram links carry it and the address
  /// bar hides it, so matching the string would have opened a second tab beside
  /// the one it was looking at.
  @Test("host matching ignores the www prefix")
  func hostMatchingIgnoresWWW() {
    #expect(BiDiClient.host(of: "https://www.instagram.com/direct/t/17/") == "instagram.com")
    #expect(BiDiClient.host(of: "https://instagram.com/") == "instagram.com")
    #expect(BiDiClient.host(of: "about:blank") == nil, "a blank tab is on no site")
    #expect(BiDiClient.host(of: nil) == nil)
  }
}

@Suite("DOM bounds are screen bounds — regression")
struct DOMBoundsRegressionTests {

  private func snapshot(originX: Double, originY: Double) -> BiDiSnapshot {
    BiDiSnapshot([
      "url": "https://example.com/",
      "viewport": ["w": 1470.0, "h": 881.0],
      "screen": ["x": originX, "y": originY],
      "funnel": ["all": 900.0, "ready": "complete"],
      "actions": [
        [
          "id": "e0", "role": "button", "label": "Send",
          "x": 72.0, "y": 538.0, "w": 90.0, "h": 32.0,
        ]
      ],
    ])
  }

  /// **`getBoundingClientRect()` is viewport-relative; `Element.bounds` is
  /// screen space.** The accessibility tier reports screen coordinates and the
  /// overlay converts from them, so the browser tier handing over page
  /// coordinates in the same field drew the target box near the corner of the
  /// display while the control sat inside the browser window.
  ///
  /// One field cannot mean two things. This is the conversion that makes it
  /// mean one.
  @Test("a page rect is offset into screen space")
  func pageRectBecomesScreenRect() {
    let snap = snapshot(originX: 310, originY: 194)
    #expect(snap.screenOrigin == CGPoint(x: 310, y: 194))
    let action = try! #require(snap.actions.first)
    let onScreen = action.bounds.offsetBy(dx: snap.screenOrigin.x, dy: snap.screenOrigin.y)
    #expect(onScreen.origin == CGPoint(x: 382, y: 732))
    #expect(onScreen.size == CGSize(width: 90, height: 32))
  }

  /// A browser at the top-left of the display is the case where the bug is
  /// invisible, which is why it survived: the offset is zero and page
  /// coordinates happen to be screen coordinates.
  @Test("a window at the origin is the case that hid the bug")
  func windowAtOriginLooksCorrectEitherWay() {
    let snap = snapshot(originX: 0, originY: 0)
    let action = try! #require(snap.actions.first)
    let onScreen = action.bounds.offsetBy(dx: snap.screenOrigin.x, dy: snap.screenOrigin.y)
    #expect(onScreen == action.bounds)
  }

  /// A hand does not cross 800 points in a third of a second. Fitts's law puts
  /// that reach at roughly 0.7s, so the average speed has to be near 1,100
  /// points per second, not 2,600.
  @Test("the pointer moves at a speed a hand could produce")
  func pointerSpeedIsHuman() {
    let reach = 800.0
    let seconds = min(
      max(reach / Constants.HUD.pixelsPerSecond, Constants.HUD.minMoveSeconds),
      Constants.HUD.maxMoveSeconds)
    #expect(seconds > 0.5, "a long reach should not read as a jump")
    #expect(seconds < 1.2, "nor as a crawl — this still has a task to finish")
  }
}

@Suite("Executor routing — regression")
struct ExecutorRoutingRegressionTests {

  /// **`navigate` names no element, and that is not the same as being native.**
  ///
  /// Every targetless action was routed to the AX executor, which refuses
  /// `navigate` by construction — so a `--browser` task died on its first step
  /// with *"navigate (ADR 0006: browser work is deferred)"* while a perfectly
  /// good BiDi session sat open beside it. The browser tier's own entry point
  /// was unreachable.
  @Test("navigate goes to the browser when there is one")
  func navigateGoesToBiDi() throws {
    let bidi = BiDiExecutor(
      client: BiDiClient(port: 9333, makeTransport: { _ in FakeBiDiTransport(replies: []) }),
      source: BiDiSource(
        client: BiDiClient(port: 9333, makeTransport: { _ in FakeBiDiTransport(replies: []) })))
    let registry = ExecutorRegistry(
      ax: AXExecutor(source: AXSource(appName: "Zen", pid: 1)),
      captured: CapturedExecutor(pid: 1, appName: "Zen", frameHash: { nil }),
      bidi: bidi)
    let chosen = try registry.executor(for: nil, kind: .navigate)
    #expect(chosen is BiDiExecutor)
  }

  /// `openApp` stays native even in a browser task: launching an application is
  /// a native operation whatever the eventual target world turns out to be.
  @Test("openApp stays native even with a browser open")
  func openAppStaysNative() throws {
    let bidi = BiDiExecutor(
      client: BiDiClient(port: 9333, makeTransport: { _ in FakeBiDiTransport(replies: []) }),
      source: BiDiSource(
        client: BiDiClient(port: 9333, makeTransport: { _ in FakeBiDiTransport(replies: []) })))
    let registry = ExecutorRegistry(
      ax: AXExecutor(source: AXSource(appName: "Zen", pid: 1)),
      captured: CapturedExecutor(pid: 1, appName: "Zen", frameHash: { nil }),
      bidi: bidi)
    #expect(try registry.executor(for: nil, kind: .openApp) is AXExecutor)
  }

  /// With no browser session, `navigate` must still fail loudly rather than
  /// silently doing something else.
  @Test("navigate without a browser is refused, not rerouted")
  func navigateWithoutBrowser() throws {
    let registry = ExecutorRegistry(
      ax: AXExecutor(source: AXSource(appName: "Zen", pid: 1)),
      captured: CapturedExecutor(pid: 1, appName: "Zen", frameHash: { nil }),
      bidi: nil)
    #expect(try registry.executor(for: nil, kind: .navigate) is AXExecutor)
  }
}

@Suite("BiDi session lifecycle — regression")
struct BiDiSessionRegressionTests {

  /// **The leak.** `close()` used to cancel the socket and nothing else, which
  /// left the session alive inside the browser, bound to a connection that no
  /// longer existed. Every later `session.new` was refused with *"Maximum
  /// number of active sessions"*, and no retry recovers from it — the browser
  /// has to be killed. Found by running it twice.
  @Test("close ends the BiDi session before cancelling the socket")
  func closeEndsTheSession() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1),  // session.new
      ok(2, oneContext),  // browsingContext.getTree
      ok(3),  // session.end
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    await client.close()

    let methods = await transport.methods()
    #expect(methods == ["session.new", "browsingContext.getTree", "session.end"])
    #expect(methods.last == "session.end", "the session must be ended, not just dropped")
  }

  /// **The other half of the leak, and the one that actually bit.** `close()`
  /// ends the session on the way out, but a process that dies before reaching
  /// it cannot. The browser is then left running, listening, and undrivable:
  /// `session.new` is refused with *"Maximum number of active sessions"* while
  /// every command on the new connection is refused with *"WebDriver session
  /// does not exist, or is not active"*.
  ///
  /// Observed on a real machine — the listening socket sat in `CLOSE_WAIT` with
  /// no client process alive.
  ///
  /// The old code logged "reusing the existing session" and carried on, which
  /// can never work: a BiDi session belongs to the socket that created it.
  @Test("a session held by a dead connection is named, not worked around")
  func orphanedSessionIsNamed() async throws {
    let transport = FakeBiDiTransport(replies: [
      err(1, "Maximum number of active sessions")
    ])
    let client = BiDiClient(
      port: 9333, connectTimeout: .milliseconds(200), retryDelay: .milliseconds(10),
      makeTransport: { _ in transport }
    )
    await #expect(throws: BiDiError.sessionHeldElsewhere(port: 9333)) {
      try await client.connect()
    }
  }

  /// It must not be reported as `notListening`. The port was answering
  /// perfectly well, and calling it dead sent a whole debugging session after
  /// Chrome DevTools endpoints that Firefox has never served.
  ///
  /// And it must not be retried. Nothing is starting up — a browser is holding
  /// a session for a client that is gone, and it will hold it until something
  /// ends it, so twenty-three attempts cost twenty-three times as long to reach
  /// the same answer.
  @Test("an orphaned session is not retried and not called a dead port")
  func orphanedSessionIsNotRetried() async throws {
    let transport = FakeBiDiTransport(replies: [
      err(1, "Maximum number of active sessions"),
      err(2, "Maximum number of active sessions"),
      err(3, "Maximum number of active sessions"),
    ])
    let client = BiDiClient(
      port: 9333, connectTimeout: .seconds(5), retryDelay: .milliseconds(10),
      makeTransport: { _ in transport }
    )
    let started = ContinuousClock.now
    await #expect(throws: BiDiError.sessionHeldElsewhere(port: 9333)) {
      try await client.connect()
    }
    #expect(ContinuousClock.now - started < .seconds(1), "it must give up at once")
    #expect(await transport.methods() == ["session.new"], "exactly one attempt")
  }

  /// The agent drives the tab the user has open, not whichever context the
  /// browser happened to list first.
  ///
  /// Taking `contexts.first` meant it could attach to a blank tab sitting
  /// beside the real page — which looks exactly like "it opened a new empty
  /// window", and produces a step with no candidates at all.
  @Test("a loaded tab is preferred over a blank one")
  func loadedTabWins() async throws {
    let tree =
      #"{"contexts":[{"context":"blank","url":"about:blank"},"#
      + #"{"context":"real","url":"https://instagram.com/"}]}"#
    let transport = FakeBiDiTransport(replies: [ok(1), ok(2, tree)])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    #expect(try await client.context() == "real")
  }

  /// A browser showing only an empty tab is still a browser the agent can
  /// navigate, so a blank context is returned when it is all there is.
  @Test("a blank tab is still used when there is nothing else")
  func blankTabIsUsedAlone() async throws {
    let transport = FakeBiDiTransport(replies: [ok(1), ok(2, oneContext)])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    #expect(try await client.context() == "ctx-1")
  }

  @Test(
    "the pages that mean nothing is open",
    arguments: ["", "about:blank", "about:newtab", "about:home", "chrome://browser/content/x"])
  func blankURLs(url: String) {
    #expect(BiDiClient.isBlank(url))
  }

  @Test("a real page is not blank", arguments: ["https://instagram.com/", "file:///tmp/x.html"])
  func realURLs(url: String) {
    #expect(!BiDiClient.isBlank(url))
  }

  /// Closing twice, or closing something that never connected, must not throw —
  /// `close()` runs on the failure path too, and an error there would mask the
  /// failure that actually mattered.
  @Test("closing an unconnected client is a no-op")
  func closingUnconnectedIsSafe() async {
    let transport = FakeBiDiTransport(replies: [])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    await client.close()
    await client.close()
    #expect(await transport.sent.isEmpty)
  }

  /// The retry loop reconnects. Without ending the session first, N failed
  /// attempts leak N sessions — which is how one bad run poisons the browser
  /// for every run after it.
  @Test("a failed connect attempt ends its session before retrying")
  func retryDoesNotLeakSessions() async {
    // getTree fails every time, so connect() exhausts its retries.
    let transport = FakeBiDiTransport(
      replies: (1...40).map { id in
        id % 2 == 1 ? ok(id) : err(id, "no such context")
      }
    )
    // A short ceiling and no sleep: this test is about what the retry path
    // *does*, not how long the real one waits.
    let client = BiDiClient(
      port: 9333, connectTimeout: .milliseconds(200), retryDelay: .zero,
      makeTransport: { _ in transport }
    )
    try? await client.connect()

    let methods = await transport.methods()
    let newCount = methods.filter { $0 == "session.new" }.count
    let endCount = methods.filter { $0 == "session.end" }.count
    #expect(newCount > 1, "the test needs more than one attempt to be meaningful")
    #expect(endCount >= newCount - 1, "every attempt but the last must clean up after itself")
  }

  /// **This test used to assert the opposite, and it passed — because the fake
  /// agreed with it.**
  ///
  /// It scripted `session.new` being refused and `browsingContext.getTree`
  /// answering anyway, then concluded that a refused session is survivable. No
  /// real browser behaves that way: a BiDi session belongs to the socket that
  /// created it, so the connection that could not create one cannot use one.
  /// The live server returns *"WebDriver session does not exist, or is not
  /// active"*, which is what an actual run finally showed.
  ///
  /// Kept as a reminder that a fake written from an assumption will confirm the
  /// assumption. What it scripts now is what the browser actually sends.
  @Test("a refused session means every later command is refused too")
  func refusedSessionMeansRefusedCommands() async throws {
    let transport = FakeBiDiTransport(replies: [
      err(1, "Maximum number of active sessions"),
      err(2, "WebDriver session does not exist, or is not active"),
    ])
    let client = BiDiClient(
      port: 9333, connectTimeout: .milliseconds(200), retryDelay: .milliseconds(10),
      makeTransport: { _ in transport }
    )
    await #expect(throws: BiDiError.sessionHeldElsewhere(port: 9333)) {
      try await client.connect()
    }
    // And it never got as far as asking, because asking was pointless.
    #expect(await transport.methods() == ["session.new"])
  }
}

@Suite("Browser launch decision — regression")
struct BrowserLaunchRegressionTests {

  /// Records what the launcher actually did to the machine.
  final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) {
      lock.lock()
      entries.append(entry)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }

  static func probes(
    listening: Bool,
    running: [Int32],
    journal: Journal
  ) -> BrowserLauncher.Probes {
    BrowserLauncher.Probes(
      isListening: { _ in listening },
      runningBrowsers: { _ in running },
      binaryExists: { _ in true },
      quit: { _ in journal.record("quit") },
      waitForExit: { _, _ in },
      launch: { _, _, _ in
        journal.record("launch")
        return 4242
      }
    )
  }

  /// **The stacked windows.** Launching used to live inside the connect retry
  /// loop, so every failed attempt started another browser — each grabbing a
  /// profile, none of them reachable. What the user saw was a pile of empty
  /// windows next to the browser they were working in.
  @Test("a browser already listening is attached to, never relaunched")
  func attachesInsteadOfLaunching() async throws {
    let journal = Journal()
    let handle = try await BrowserLauncher.ensureDrivable(
      allowRestart: true,
      probes: Self.probes(listening: true, running: [999], journal: journal)
    )
    #expect(journal.all.isEmpty, "nothing was launched and nothing was quit")
    #expect(handle.restartedExistingBrowser == false)
  }

  @Test("with nothing running, it launches once and quits nothing")
  func launchesOnceWhenNothingRuns() async throws {
    let journal = Journal()
    let handle = try await BrowserLauncher.ensureDrivable(
      allowRestart: true,
      probes: Self.probes(listening: false, running: [], journal: journal)
    )
    #expect(journal.all == ["launch"])
    #expect(handle.restartedExistingBrowser == false)
    #expect(handle.processIdentifier == 4242)
  }

  /// The debug port cannot be added to a running process, so a browser without
  /// one has to be restarted — quit first, so Gecko saves the session.
  @Test("a portless running browser is quit before relaunching")
  func quitsBeforeRelaunch() async throws {
    let journal = Journal()
    let handle = try await BrowserLauncher.ensureDrivable(
      allowRestart: true,
      probes: Self.probes(listening: false, running: [12540], journal: journal)
    )
    #expect(journal.all == ["quit", "launch"], "quit must come first, or the profile is locked")
    #expect(handle.restartedExistingBrowser == true)
  }

  /// Closing a window the user is working in is the caller's decision, never a
  /// silent default inside the launcher.
  @Test("without permission to restart, it refuses instead of quitting")
  func refusesToRestartWithoutPermission() async {
    let journal = Journal()
    await #expect(throws: BrowserLauncher.LaunchError.self) {
      _ = try await BrowserLauncher.ensureDrivable(
        allowRestart: false,
        probes: Self.probes(listening: false, running: [12540], journal: journal)
      )
    }
    #expect(journal.all.isEmpty, "nothing was quit and nothing was launched")
  }

  @Test("a missing binary fails before touching anything")
  func missingBinaryFailsEarly() async {
    let journal = Journal()
    var probes = Self.probes(listening: false, running: [], journal: journal)
    probes.binaryExists = { _ in false }
    await #expect(throws: BrowserLauncher.LaunchError.self) {
      _ = try await BrowserLauncher.ensureDrivable(allowRestart: true, probes: probes)
    }
    #expect(journal.all.isEmpty)
  }
}
