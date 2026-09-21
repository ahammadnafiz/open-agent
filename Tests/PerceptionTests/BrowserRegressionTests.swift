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
      ok(5, #"{"result":{"type":"string","value":"visible"}}"#),  // where they are
      ok(6, #"{"userContexts":[{"userContext":"default"}]}"#),  // one jar
      ok(7, #"{"cookies":[]}"#),  // holding nothing for this site
      // window.open, answering with the WindowProxy for the named tab
      ok(8, #"{"result":{"type":"window","value":{"context":"agent-tab"}}}"#),
      ok(9),  // browsingContext.activate
      ok(10),  // browsingContext.navigate
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

  /// **A new tab opens where you are.** `window.open` inherits its opener's
  /// container, and containers are separate cookie jars, so a tab opened from
  /// whichever context `getTree` happened to return lands in a jar the user was
  /// never signed in to. Measured: the agent's own x.com tab was served the
  /// login page while their X tab, in the workspace they were looking at, was
  /// signed in — and it reads as "the agent logged me out".
  @Test("a new tab is opened from the tab the user is looking at")
  func newTabOpensWhereTheUserIs() async throws {
    let tree = #"""
      {"contexts":[{"context":"background","url":"https://news.example/"},
                   {"context":"onscreen","url":"https://mail.example/"}]}
      """#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, tree),
      ok(3, tree),  // tab(for:) — neither is on x.com
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name
      ok(5, #"{"result":{"type":"string","value":""}}"#),
      ok(6, #"{"result":{"type":"string","value":"hidden"}}"#),  // background
      ok(7, #"{"result":{"type":"string","value":"visible"}}"#),  // onscreen
      ok(8, #"{"userContexts":[{"userContext":"default"}]}"#),
      ok(9, #"{"cookies":[]}"#),
      ok(10, #"{"result":{"type":"window","value":{"context":"agent-tab"}}}"#),
      ok(11),  // activate
      ok(12),  // navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://x.com/home")

    let opener = await transport.sent.first { $0.contains("window.open") }
    #expect(opener?.contains("onscreen") == true, "opened from the workspace they were in")
  }

  /// **`default` is the jar nobody is signed in to.** The browser reported five
  /// containers; the user's X tab was in `8c0e920f…` and signed in, and the
  /// agent's own x.com tab was in `default` and served the login page. Reusing
  /// a tab like that is how the next task reports a login wall on a site the
  /// user is logged in to, so it is dropped — and closed, because a signed-out
  /// tab the agent left behind is exactly what they keep pointing at.
  @Test("an agent tab stranded in the default container is closed, not reused")
  func strandedAgentTabIsClosed() async throws {
    let tree = #"""
      {"contexts":[{"context":"stranded","url":"https://x.com/","userContext":"default"},
                   {"context":"theirs","url":"https://mail.example/","userContext":"8c0e920f"}]}
      """#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, tree),
      ok(3, tree),  // tab(for:)
      ok(4, #"{"result":{"type":"string","value":"__open_agent_tab"}}"#),  // ours
      ok(5, #"{"result":{"type":"string","value":""}}"#),  // theirs
      ok(6),  // browsingContext.close
      ok(7, #"{"result":{"type":"string","value":"visible"}}"#),  // where they are
      ok(8, #"{"userContexts":[{"userContext":"default"}]}"#),
      ok(9, #"{"cookies":[]}"#),
      ok(10, #"{"result":{"type":"window","value":{"context":"fresh"}}}"#),
      ok(11),  // activate
      ok(12),  // navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://news.example/")

    let sent = await transport.sent
    let closed = sent.first { $0.contains("browsingContext.close") }
    #expect(closed?.contains("stranded") == true, "the stranded tab was closed")
    let opener = sent.first { $0.contains("window.open") }
    #expect(opener?.contains("theirs") == true, "the new tab was opened in their container")
    #expect(try await client.context() == "fresh")
  }

  /// **The cookies are the evidence, and they survive a restart.**
  ///
  /// Remembering which container the user browses in was tried and cannot
  /// work: the ids are per session. The same four containers came back as
  /// `8c0e920f…, aabd5dbe…, e804e1bf…, 693a46d5…` before a restart and
  /// `1ef8908b…, 590015db…, 8018f1f3…, 92fe77e0…` after it.
  ///
  /// A jar that already holds the site's cookies is the jar with the session
  /// in it, and asking costs no tab, no guess and nothing remembered.
  @Test("a tab is created in the container that holds the site's cookies")
  func newTabGoesWhereTheCookiesAre() async throws {
    let tree = #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, tree),
      ok(3, tree),  // tab(for:) — nothing on x.com
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name
      ok(5, #"{"result":{"type":"string","value":"visible"}}"#),  // in `default`
      ok(6, #"{"userContexts":[{"userContext":"default"},{"userContext":"aaa"},{"userContext":"bbb"}]}"#),
      // Asked in sorted order — aaa, bbb, then default, which is a jar like
      // any other and used to be skipped without ever being looked in.
      ok(7, #"{"cookies":[]}"#),  // aaa — signed out here
      // **The leading dot is the point.** This is how sites really scope a
      // session cookie, and `storage.getCookies`' own `domain` filter is an
      // exact string match, so asking it for `x.com` returns none of these.
      ok(8, #"{"cookies":[{"name":"auth_token","domain":".x.com"},{"name":"ct0","domain":".x.com"}]}"#),
      ok(9, #"{"cookies":[{"name":"guest_id","domain":".x.com"}]}"#),  // default — browsed, not signed in
      ok(10, #"{"context":"fresh"}"#),  // browsingContext.create
      ok(11),  // window.name
      ok(12),  // activate
      ok(13),  // navigate
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://x.com/home")

    let created = await transport.sent.first { $0.contains("browsingContext.create") }
    #expect(created?.contains("bbb") == true, "created in the jar holding the session")
    #expect(try await client.context() == "fresh")

    let asked = await transport.sent.filter { $0.contains("storage.getCookies") }
    #expect(asked.count == 3, "every jar is asked, default included")
    // **The protocol's own `domain` filter is an exact string match**, so it
    // finds nothing for any site that scopes its session to a parent domain —
    // measured as 0 of 10 real cookies for facebook.com and 0 of 17 for
    // instagram.com, against 3 of 15 for x.com, which stores them on the bare
    // name. Passing it is what made signing in change nothing anywhere but X.
    #expect(
      asked.allSatisfy { !$0.contains(#""domain""#) },
      "the domain filter is back, and it cannot see a cookie on a parent domain")
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
      ok(5, #"{"result":{"type":"string","value":"visible"}}"#),  // where they are
      ok(6, #"{"userContexts":[{"userContext":"default"}]}"#),
      ok(7, #"{"cookies":[]}"#),
      ok(8, #"{"result":{"type":"window","value":{"context":"agent-tab"}}}"#),
      ok(9),  // activate
      ok(10),  // first navigate
      ok(11, after),  // tab(for:) — the tab it made is in the tree now
      ok(12),  // second navigate
      ok(13, after),
      ok(14),  // third navigate
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

  /// **The pointer narrates a decision and must not outlast it.**
  ///
  /// This assertion used to say the opposite, and it was argued well: a hand
  /// does not cross 800 points in a third of a second, Fitts's law puts that
  /// reach near 0.7s, so the pointer should take at least half a second. That
  /// is the right model for predicting a human and the wrong one for drawing
  /// an agent — nothing here is reaching, and the decision was already made
  /// before the first frame.
  ///
  /// Measured on a real X step: `act=1011ms` against `judge=626ms`. Drawing
  /// the decision cost more than making it, on every targeted step of every
  /// task. So the contract is bounded by the work now, not by anatomy.
  ///
  /// Travel still has to read as travel — below roughly 0.1s a movement is a
  /// cut rather than a motion — and the anticipation ring, which is the part
  /// that actually informs, is untouched.
  @Test("the pointer narrates a step without outlasting it")
  func pointerDoesNotOutlastTheDecision() {
    let reach = 800.0
    let seconds = min(
      max(reach / Constants.HUD.pixelsPerSecond, Constants.HUD.minMoveSeconds),
      Constants.HUD.maxMoveSeconds)
    #expect(seconds >= 0.1, "below this a movement reads as a cut, not a motion")
    #expect(
      Constants.HUD.worstCaseOverheadSeconds < 0.6,
      "the overlay must not cost more than the decision it draws — judge measures ~0.6s")
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

/// What typing costs, and why it is shaped the way it is.
@Suite("Typing cadence — regression")
struct TypingCadenceTests {

  /// **The pause is the expensive part, not the keystroke.** Measured against
  /// a live Firefox on a plain text input: 54 key ticks with no pauses cost
  /// 10–19ms, while the same 27 characters with a pause each cost 1800–2151ms
  /// for 675ms of pause asked for. A `pause` tick costs roughly what it asks
  /// plus 45ms of its own, so the cadence is bought in bursts.
  @Test("one pause carries a whole burst")
  func onePausePerBurst() throws {
    let group = Constants.Typing.webKeystrokeGroup
    let sequence = BiDiExecutor.keySequence(String(repeating: "a", count: group * 2))
    let actions = try #require(sequence["actions"] as? [[String: Any]])

    let pauses = actions.filter { $0["type"] as? String == "pause" }
    #expect(pauses.count == 2, "a pause per character is what made a sentence cost two seconds")
    #expect(actions.filter { $0["type"] as? String == "keyDown" }.count == group * 2)
    for pause in pauses {
      #expect(
        pause["duration"] as? Int == Constants.Typing.webKeystrokeMilliseconds * group,
        "the burst has to carry the cadence it replaced, or typing just got faster")
    }
  }

  /// Nothing follows the last character, so a trailing pause buys no cadence
  /// and costs another tick's overhead.
  @Test("a part-filled last burst ends without a pause")
  func noTrailingPause() throws {
    let group = Constants.Typing.webKeystrokeGroup
    let sequence = BiDiExecutor.keySequence(String(repeating: "a", count: group + 1))
    let actions = try #require(sequence["actions"] as? [[String: Any]])

    #expect(actions.filter { $0["type"] as? String == "pause" }.count == 1)
    #expect(actions.last?["type"] as? String == "keyUp")
  }

  /// **The cadence is what a field gets when it has asked for it, not by
  /// default.** Measured on x.com's composer: 42 characters cost `act=2147ms`
  /// paced and `act=518ms` unpaced, and the read-back confirmed the same text
  /// both times. Paying 1.6s on every `type` to be ready for the fields that
  /// need per-keystroke timing is the wrong way round — try it fast, and let
  /// the field say.
  @Test("an unpaced burst carries every keystroke and no pauses")
  func unpacedBurstHasNoPauses() throws {
    let text = String(repeating: "a", count: Constants.Typing.webKeystrokeGroup * 3)
    let sequence = BiDiExecutor.keySequence(text, paced: false)
    let actions = try #require(sequence["actions"] as? [[String: Any]])

    #expect(actions.filter { $0["type"] as? String == "pause" }.isEmpty)
    #expect(actions.filter { $0["type"] as? String == "keyDown" }.count == text.count)
    #expect(actions.filter { $0["type"] as? String == "keyUp" }.count == text.count)
  }

  /// **A retry that repeats the failed strategy is just waiting for a
  /// different answer.** The two attempts in `type(_:into:)` are only worth
  /// two attempts if they differ, so the burst and the paced retry must not
  /// produce the same sequence.
  @Test("the retry types differently from the first attempt")
  func retryDiffersFromFirstAttempt() throws {
    let text = String(repeating: "a", count: Constants.Typing.webKeystrokeGroup * 2)
    let burst = try #require(
      BiDiExecutor.keySequence(text, paced: false)["actions"] as? [[String: Any]])
    let paced = try #require(
      BiDiExecutor.keySequence(text, paced: true)["actions"] as? [[String: Any]])

    #expect(burst.count < paced.count, "the paced retry has to actually pace something")
    #expect(paced.contains { $0["type"] as? String == "pause" })
  }
}


/// Which browser, said out loud.
@Suite("Naming the browser being driven")
struct BrowserNamingTests {

  @Test("the app name comes from the binary path")
  func appNameFromPath() {
    #expect(BrowserLauncher.appName(of: "/Applications/Zen.app/Contents/MacOS/zen") == "Zen")
    #expect(
      BrowserLauncher.appName(of: "/Applications/Firefox.app/Contents/MacOS/firefox")
        == "Firefox")
    // No bundle in the path: fall back to the executable's own name rather
    // than inventing one.
    #expect(BrowserLauncher.appName(of: "/usr/local/bin/zen") == "zen")
  }

  /// **The quit was aimed at a literal while the wait was aimed at a
  /// parameter.** `ensureDrivable` took the binary to launch but always sent
  /// the quit to `"Zen"`, so pointing it at any other browser would ask one
  /// application to close and then wait for a different one to exit — a wait
  /// that can only time out.
  @Test("it quits the browser it was asked to drive, not a hardcoded one")
  func quitsTheBrowserItWasGiven() async throws {
    let quitTarget = BrowserLaunchRegressionTests.Journal()
    let probes = BrowserLauncher.Probes(
      isListening: { _ in false },
      runningBrowsers: { _ in [999] },
      binaryExists: { _ in true },
      quit: { name in quitTarget.record(name) },
      waitForExit: { _, _ in },
      launch: { _, _, _ in 4242 }
    )

    _ = try await BrowserLauncher.ensureDrivable(
      binary: "/Applications/Firefox.app/Contents/MacOS/firefox",
      allowRestart: true,
      probes: probes
    )

    #expect(quitTarget.all == ["Firefox"])
  }
}


/// **Typing was three assumptions in a row and no check**: focus was asked for
/// and the answer discarded, the field was cleared and nobody looked, the keys
/// were sent and nothing read them back. What that produces when any of them
/// quietly fails is a field holding the message twice —
/// `hello world from open-agenthello world from open-agent`.
@Suite("Typing leaves exactly what was asked for")
struct TypeIsIdempotentTests {

  /// `{x, y}` from `validate`, then whatever `focus` returns, then the field
  /// read back.
  static func point() -> String {
    #"""
    {"result":{"type":"object","value":[
      [{"type":"string","value":"x"},{"type":"number","value":10.0}],
      [{"type":"string","value":"y"},{"type":"number","value":20.0}]]}}
    """#
  }

  static func field(_ text: String) -> String {
    #"""
    {"result":{"type":"object","value":[
      [{"type":"string","value":"text"},{"type":"string","value":"\#(text)"}]]}}
    """#
  }

  static func action(_ text: String) -> Action {
    Action(
      kind: .type,
      target: .dom(handle: "e5", selector: "textbox[Post text]", label: "Post text", submitLabel: ""),
      payload: text,
      rationale: "the compose box")
  }

  static func executor(_ transport: FakeBiDiTransport) async throws -> BiDiExecutor {
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    return BiDiExecutor(client: client, source: BiDiSource(client: client))
  }

  @Test("a field that takes the text first time is not typed into twice")
  func oneAttemptWhenItWorks() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1),  // session.new
      ok(2, oneContext),  // resolveContext
      ok(3, Self.point()),  // validate
      ok(4, #"{"result":{"type":"object","value":[]}}"#),  // focus
      ok(5),  // clear
      ok(6),  // the keys
      ok(7, Self.field("hello")),  // and the field holds them
    ])
    let result = try await Self.executor(transport).execute(Self.action("hello"))

    #expect(result.dispatched)
    let typed = await transport.sent.filter { $0.contains("performActions") }
    #expect(typed.count == 2, "one clear and one type, not a second pass")
  }

  @Test("a field left holding the text twice is cleared and retyped")
  func retypesWhenTheFieldIsWrong() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1), ok(2, oneContext),
      ok(3, Self.point()),  // validate
      ok(4, #"{"result":{"type":"object","value":[]}}"#),  // focus
      ok(5), ok(6),  // clear, keys
      ok(7, Self.field("hellohello")),  // doubled — exactly the reported bug
      ok(8, #"{"result":{"type":"object","value":[]}}"#),  // focus again
      ok(9), ok(10),  // clear, keys
      ok(11, Self.field("hello")),  // and now it is right
    ])
    let result = try await Self.executor(transport).execute(Self.action("hello"))

    #expect(result.dispatched)
    let typed = await transport.sent.filter { $0.contains("performActions") }
    #expect(typed.count == 4, "it should have cleared and retyped once")
  }

  /// Carrying on to a `publish` with the wrong text in the box is the outcome
  /// worth failing to avoid.
  @Test("a field that refuses twice fails the step rather than publishing it")
  func refusesAfterTwoAttempts() async throws {
    let transport = FakeBiDiTransport(replies: [
      ok(1), ok(2, oneContext),
      ok(3, Self.point()),
      ok(4, #"{"result":{"type":"object","value":[]}}"#),
      ok(5), ok(6),
      ok(7, Self.field("hellohello")),
      ok(8, #"{"result":{"type":"object","value":[]}}"#),
      ok(9), ok(10),
      ok(11, Self.field("hellohello")),  // still wrong
    ])
    let executor = try await Self.executor(transport)

    await #expect(throws: (any Error).self) {
      _ = try await executor.execute(Self.action("hello"))
    }
  }
}


/// **Counting cookies ranks jars by how much a site tracked you.** Measured on
/// Slack, where two containers are signed in to different workspaces: 21
/// cookies against 16, and the five extra were `_ga`, `_cs_c`, `_cs_id`,
/// `cjConsent` and `PageCount`.
@Suite("The jar with the session, not the jar with the analytics")
struct SessionCookieRankingTests {

  @Test("a jar with fewer cookies but real session cookies wins")
  func sessionCookiesOutrankVolume() async throws {
    let tree = #"{"contexts":[{"context":"users-tab","url":"https://news.example/"}]}"#
    let transport = FakeBiDiTransport(replies: [
      ok(1),
      ok(2, tree),
      ok(3, tree),  // tab(for:) — nothing on x.com
      ok(4, #"{"result":{"type":"string","value":""}}"#),  // window.name
      ok(5, #"{"result":{"type":"string","value":"visible"}}"#),
      ok(6, #"{"userContexts":[{"userContext":"default"},{"userContext":"aaa"},{"userContext":"bbb"}]}"#),
      // aaa: browsed a lot, signed in to nothing. Five cookies, every one of
      // them set by a script, which is what analytics can be and a session
      // cookie cannot.
      ok(7, #"""
        {"cookies":[
          {"name":"_ga","domain":".x.com","httpOnly":false},
          {"name":"_cs_c","domain":".x.com","httpOnly":false},
          {"name":"_cs_id","domain":".x.com","httpOnly":false},
          {"name":"cjConsent","domain":".x.com","httpOnly":false},
          {"name":"PageCount","domain":".x.com","httpOnly":false}]}
        """#),
      // bbb: fewer cookies, and the ones that matter.
      ok(8, #"""
        {"cookies":[
          {"name":"auth_token","domain":".x.com","httpOnly":true},
          {"name":"kdt","domain":".x.com","httpOnly":true}]}
        """#),
      ok(9, #"{"cookies":[]}"#),  // default
      ok(10, #"{"context":"fresh"}"#),
      ok(11), ok(12), ok(13),
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    try await client.navigate(to: "https://x.com/home")

    let created = await transport.sent.first { $0.contains("browsingContext.create") }
    #expect(
      created?.contains("bbb") == true,
      "it followed the cookie count into the jar that had only been tracked")
  }
}


/// **An add-on's page is a privileged context and nothing can be scripted in
/// it.** A tab suspender had parked a real page behind
/// `moz-extension://…/suspended.html`; that tab was in a named container, and
/// the container preference chose it over an ordinary page in `default`. The
/// run died on its first observation with *"System access is required. Start
/// Zen with -remote-allow-system-access"* — a message about a launch flag, for
/// a problem that was a choice of tab.
@Suite("Never drive the browser's own pages")
struct PrivilegedContextTests {

  @Test("an extension page is not adopted, even from a named container")
  func extensionPagesAreSkipped() async throws {
    let tree = #"""
      {"contexts":[
        {"context":"suspended","url":"moz-extension://abc/suspended.html?origUrl=https%3A%2F%2Fgithub.com","userContext":"workspace"},
        {"context":"real","url":"https://news.example/","userContext":"default"}]}
      """#
    let transport = FakeBiDiTransport(replies: [ok(1), ok(2, tree)])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()

    #expect(
      try await client.context() == "real",
      "it adopted the add-on's page because the add-on's page was in a workspace")
  }

  @Test("the browser's own surfaces are privileged, an empty page is not")
  func whatCountsAsPrivileged() {
    #expect(BiDiClient.isPrivileged("moz-extension://abc/suspended.html"))
    #expect(BiDiClient.isPrivileged("chrome://browser/content/browser.xhtml"))
    #expect(BiDiClient.isPrivileged("about:config"))
    #expect(BiDiClient.isPrivileged("view-source:https://example.com"))
    // `about:blank` is an ordinary content context that scripts run in, and a
    // valid tab to open from — a new tab inherits its container, which is how
    // the agent lands in the jar the user is signed in to.
    #expect(!BiDiClient.isPrivileged("about:blank"))
    #expect(!BiDiClient.isPrivileged("https://example.com"))
  }
}

/// Re-resolving a target must not be what makes it look stale.
@Suite("The guard is taken before the element is moved")
struct TargetGuardOrderingTests {

  /// **The validation scrolled the element, then accused it of moving.**
  ///
  /// `__oaGuard` is `role|left|top|disabled`, taken from
  /// `getBoundingClientRect()`, which is viewport-relative — so `top` changes
  /// whenever the page scrolls. `validate` scrolls the target to the centre of
  /// the viewport before reading it, which changes `top` for any target that
  /// was not already there.
  ///
  /// Measured on prosemirror.net: the snapshot recorded `textbox|377|852|0`,
  /// re-resolution reported `textbox|377|321|0`, and the click was refused
  /// with *"an unchanged target"*. Same element, same node handle — the 531
  /// points of movement were the agent's own scroll. Every target below the
  /// fold met this, which on a page longer than one screen is most of them.
  @Test("the fingerprint is computed before scrollIntoView")
  func guardPrecedesScroll() throws {
    let script = BiDiExecutor.resolveScript(handle: "e19")
    // The call, not the word — the script carries a comment explaining this
    // very ordering, and matching that instead would pass for the wrong reason.
    let guardAt = try #require(script.range(of: "window.__oaGuard(el"))
    let scrollAt = try #require(script.range(of: "el.scrollIntoView("))
    #expect(
      guardAt.lowerBound < scrollAt.lowerBound,
      "scrolling the target first is what made it fail its own staleness check")
  }

  /// The click point is the opposite case and must stay after the scroll: it
  /// is the one value that has to describe where the element is *now*.
  /// ADR 0007 allows exactly this, and nothing else, to be measured at act
  /// time.
  @Test("the click point is computed after scrollIntoView")
  func clickPointFollowsScroll() throws {
    let script = BiDiExecutor.resolveScript(handle: "e19")
    let scrollAt = try #require(script.range(of: "el.scrollIntoView("))
    let rectAt = try #require(script.range(of: "el.getBoundingClientRect()"))
    #expect(
      scrollAt.lowerBound < rectAt.lowerBound,
      "the click point has to describe where the element ended up")
  }
}


/// **A scroll dispatched a click.** `scroll` shared the branch that handles
/// `click` in both executors, so the verb sent `pointerDown`/`pointerUp` at
/// its target. On a list — the one place anyone plans a scroll — that presses
/// the first row and navigates away from the page the plan was about, and the
/// next observation answers honestly about somewhere else entirely.
@Suite("A scroll is not a click")
struct ScrollIsNotAClickTests {

  static func point() -> String {
    #"""
    {"result":{"type":"object","value":[
      [{"type":"string","value":"x"},{"type":"number","value":10.0}],
      [{"type":"string","value":"y"},{"type":"number","value":20.0}]]}}
    """#
  }

  static let action = Action(
    kind: .scroll,
    target: .dom(handle: "e5", selector: "list[Issues]", label: "Issues", submitLabel: ""),
    payload: nil,
    rationale: "see the rest of the list")

  @Test("the browser tier sends a wheel, never a pointer press")
  func scrollUsesTheWheel() async throws {
    let transport = FakeBiDiTransport(replies: [
      scrollOK(1),  // session.new
      scrollOK(2, scrollOneContext),  // resolveContext
      scrollOK(3, Self.point()),  // validate
      scrollOK(4),  // the scroll itself
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    let executor = BiDiExecutor(client: client, source: BiDiSource(client: client))

    let result = try await executor.execute(Self.action)
    #expect(result.dispatched)

    let dispatched = await transport.sent.filter { $0.contains("performActions") }
    let sent = try #require(dispatched.first)
    #expect(sent.contains("wheel"), "a scroll is a wheel action")
    #expect(!sent.contains("pointerDown"), "pressing the target is the bug, not the fallback")
  }

  /// The pixel tier resolves every kind to a click at the bbox centre, so a
  /// scroll that escalated down the ladder would press the target after the
  /// browser tier had refused to. It is enumerated and refused instead.
  @Test("the pixel tier refuses rather than clicking")
  func capturedRefusesScroll() async throws {
    let executor = CapturedExecutor(
      pid: 0, appName: "Zen", frameHash: { "hash" })
    let scroll = Action(
      kind: .scroll,
      target: .captured(
        bbox: CGRect(x: 0, y: 0, width: 80, height: 30), label: "Issues",
        provenance: .detectorBox),
      payload: nil,
      rationale: "see the rest of the list")

    await #expect(throws: ExecutionError.self) {
      _ = try await executor.execute(scroll)
    }
  }
}

private func scrollOK(_ id: Int, _ result: String = "{}") -> String {
  #"{"type":"success","id":\#(id),"result":\#(result)}"#
}

private let scrollOneContext = #"{"contexts":[{"context":"ctx-1","url":"about:blank"}]}"#


/// **"Zen is not running" was said about a browser that was running, driving a
/// page, and listening on its debug port** — every window of it was on another
/// Space. The on-screen window list is the only thing `pid(forApp:)` consulted,
/// so an app that was merely elsewhere was indistinguishable from an app that
/// was absent, and the next hour of debugging went to name matching.
@Suite("Not running is not the same as not here")
struct WindowDiagnosisTests {

  @Test("the full window list is a superset of the on-screen one")
  func fullListIsWider() {
    let onScreen = WindowGuard.windows()
    let everywhere = WindowGuard.windows(onScreenOnly: false)
    #expect(everywhere.count >= onScreen.count)
    for window in onScreen {
      #expect(
        everywhere.contains { $0.windowID == window.windowID },
        "an on-screen window must also appear in the unfiltered list")
    }
  }

  /// A name nothing owns is the one case that is still `appNotRunning`.
  @Test("an app with no window anywhere is reported as not running")
  func absentAppIsNotRunning() {
    #expect(throws: PerceptionError.self) {
      _ = try WindowGuard.pid(forApp: "NoSuchApplication_\(UUID().uuidString)")
    }
  }
}
