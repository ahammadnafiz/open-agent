import Foundation

/// Errors from the WebDriver BiDi transport.
extension BiDiError {
  /// Whether this error means *what is on that port cannot be driven*, as
  /// opposed to *this request was wrong*.
  ///
  /// **A listening port is not a drivable browser, and treating it as one left
  /// every run after an abandoned one failing until a human killed the
  /// browser.** `BrowserLauncher.ensureDrivable` attaches whenever something
  /// answers on the port, so a browser left over from a run that died gets
  /// adopted rather than replaced — and then the next BiDi call fails.
  /// Reported from a real session: *"open-agent logged 'attaching to Zen,
  /// already listening' instead of relaunching it, then BiDi came back
  /// noBrowsingContext ... quitting Zen freed the port; the rerun launched Zen
  /// itself and worked."*
  ///
  /// All three have the same remedy and no other one:
  ///
  /// * `sessionHeldElsewhere` — the one WebDriver session belongs to a dead
  ///   connection, and only the owning process exiting releases it.
  /// * `noBrowsingContext` — the session exists but there is no tab to drive,
  ///   which a fresh launch always has.
  /// * `notListening` — something holds the port without completing a
  ///   handshake. From out here a half-dead browser and a starting one look
  ///   identical, and by the time this is thrown the retry ceiling has already
  ///   been paid.
  ///
  /// Everything else is a real failure and must keep surfacing as one.
  public var meansTheBrowserIsUndrivable: Bool {
    switch self {
    case .sessionHeldElsewhere, .noBrowsingContext, .notListening: true
    default: false
    }
  }

  /// What to tell the person before their browser restarts.
  public var undrivableDiagnosis: String {
    switch self {
    case .sessionHeldElsewhere: "the browser holds a session for a client that is gone"
    case .noBrowsingContext: "the browser is listening but has no tab to drive"
    case .notListening: "the port is held by something that never completed a handshake"
    default: "the browser cannot be driven"
    }
  }
}

public enum BiDiError: Error, Equatable, Sendable {
  /// The browser never opened its debug port. Cold start is 5–7 s measured, so
  /// this is a connect-retry ceiling rather than a sleep — a fixed sleep either
  /// wastes time or races.
  case notListening(port: Int)
  /// The browser is listening, but its one WebDriver session belongs to a
  /// connection that no longer exists.
  ///
  /// **A BiDi session is owned by the socket that created it.** Firefox allows
  /// one at a time, so a process that exits without `session.end` leaves the
  /// browser running, listening, and undrivable — `session.new` is refused with
  /// *"Maximum number of active sessions"* while every command on the new
  /// connection is refused with *"WebDriver session does not exist, or is not
  /// active"*. Observed directly: the listening socket sat in `CLOSE_WAIT` with
  /// no client process left alive.
  ///
  /// Distinct from `notListening` because the remedy is the opposite. Waiting
  /// longer cannot help — nothing is starting — and reporting it as "not
  /// listening" sent a whole debugging session after a port that was answering
  /// perfectly well.
  case sessionHeldElsewhere(port: Int)
  case handshakeFailed(String)
  /// The browser answered, but with an error for this command.
  case command(method: String, message: String)
  case noBrowsingContext
  case malformedResponse(String)
  case disconnected
  /// The snapshot script threw inside the page.
  case scriptFailed(String)
  /// A site was named and no tab is showing it.
  ///
  /// Only raised when nothing is coming to fill a new tab. A plan with a
  /// `navigate` step opens one and loads it; a plan without one, and
  /// `observe`, would get a blank page and report about it as if it were the
  /// site — which is the failure this whole verb exists to avoid.
  case noTabOnSite(String)
}

/// The socket, behind a seam.
///
/// Injected so session lifecycle is testable without a browser. The bug this
/// exists to guard is not hypothetical: `close()` used to cancel the socket
/// without ending the BiDi session, which left the session alive inside the
/// browser bound to a connection that no longer existed. Every later
/// `session.new` was then refused with *"Maximum number of active sessions"* —
/// a browser that is running, listening, and undrivable until it is killed.
public protocol BiDiTransport: Sendable {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func cancel()
}

/// The live transport.
final class WebSocketTransport: BiDiTransport {
  private let task: URLSessionWebSocketTask

  init(session: URLSession, port: Int) throws {
    guard let url = URL(string: "ws://127.0.0.1:\(port)/session") else {
      throw BiDiError.handshakeFailed("bad url")
    }
    task = session.webSocketTask(with: url)
    task.resume()
  }

  func send(_ text: String) async throws { try await task.send(.string(text)) }

  func receive() async throws -> String {
    switch try await task.receive() {
    case .string(let s): return s
    case .data(let d): return String(decoding: d, as: UTF8.self)
    @unknown default: throw BiDiError.malformedResponse("unknown frame")
    }
  }

  func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

/// A minimal WebDriver BiDi client over `URLSessionWebSocketTask`.
///
/// Foundation only. `SPEC.md` § Tech Stack picked this on purpose: *"WebSocket —
/// `URLSessionWebSocketTask` — Foundation; no dependency needed."* The zero
/// dependency count is a stated feature, and BiDi is small enough that a client
/// is a few hundred lines rather than a library.
///
/// An `actor`, so command/response correlation needs no locking: BiDi multiplexes
/// events onto the same socket, and serialised sends mean a reply can be read by
/// draining until the matching `id` arrives.
public actor BiDiClient {
  private let port: Int
  private var socket: (any BiDiTransport)?
  private let makeTransport: @Sendable (Int) throws -> any BiDiTransport
  private var nextID = 1
  private var contextID: String?
  /// The tab this run opened for itself, once it has one.
  private var agentTabID: String?
  /// The container the user's own tab is in, so the agent's tab can join it.
  private var userContextID: String?
  private let connectTimeout: Duration
  private let retryDelay: Duration

  /// - Parameter connectTimeout: how long to keep retrying while the browser
  ///   starts. Cold start was measured at 5–7 s, so the default is a
  ///   connect-retry ceiling rather than a sleep. Injectable because a test
  ///   that exercises the retry path should not spend the real ceiling doing
  ///   it — a twenty-second unit test is one people stop running.
  public init(
    port: Int = Constants.Browser.bidiPort,
    connectTimeout: Duration = Constants.Browser.launchTimeout,
    retryDelay: Duration = .milliseconds(300),
    makeTransport: (@Sendable (Int) throws -> any BiDiTransport)? = nil
  ) {
    self.port = port
    self.connectTimeout = connectTimeout
    self.retryDelay = retryDelay
    if let makeTransport {
      self.makeTransport = makeTransport
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = Constants.Jev.requestTimeout.inSeconds
      let session = URLSession(configuration: configuration)
      self.makeTransport = { try WebSocketTransport(session: session, port: $0) }
    }
  }

  // MARK: - Lifecycle

  /// Connects and creates a session, retrying while the browser starts.
  ///
  /// Cold start was measured at 5–7 s, so this polls up to
  /// `Constants.Browser.launchTimeout` rather than sleeping a fixed amount.
  public func connect() async throws {
    let deadline = ContinuousClock.now + connectTimeout
    var lastError: (any Error)?

    while ContinuousClock.now < deadline {
      do {
        try await openSocket()

        // **A refused `session.new` is not something to work around.** The
        // previous code logged "reusing the existing session" and carried on,
        // which cannot work: a BiDi session belongs to the socket that created
        // it, so a session held by a dead connection can never be adopted by
        // this one. Every command that followed was refused with "WebDriver
        // session does not exist", and the retry loop tried twenty-three times
        // before reporting the port as not listening — which it was.
        //
        // Retrying cannot change it either. Nothing is starting up; a browser
        // is holding a session for a client that is gone, and it will hold it
        // until something ends it. So this leaves the loop immediately and
        // names the condition, and the caller restarts the browser.
        do {
          _ = try await send("session.new", ["capabilities": [:] as [String: Sendable]])
        } catch let error as BiDiError {
          guard case .command(_, let message) = error, message.contains("Maximum number") else {
            throw error
          }
          socket?.cancel()
          socket = nil
          throw BiDiError.sessionHeldElsewhere(port: port)
        }

        contextID = try await resolveContext()
        Log.debug("bidi connected on port \(port), context \(contextID ?? "-")")
        return
      } catch BiDiError.sessionHeldElsewhere(let port) {
        // Not a startup race. Waiting longer is waiting for nothing.
        throw BiDiError.sessionHeldElsewhere(port: port)
      } catch {
        lastError = error
        // A half-open socket left behind here is what leaks the session, so the
        // retry path tears it down the same way `close()` does.
        if socket != nil { _ = try? await send("session.end", [:]) }
        socket?.cancel()
        socket = nil
        try? await Task.sleep(for: retryDelay)
      }
    }
    Log.warn("bidi never came up on port \(port): \(lastError.map { "\($0)" } ?? "no answer")")
    throw BiDiError.notListening(port: port)
  }

  /// Ends the BiDi session, then closes the socket.
  ///
  /// **Both halves matter.** Cancelling the socket alone leaves the session
  /// alive inside the browser, bound to a connection that no longer exists, and
  /// the next `session.new` is refused with *"Maximum number of active
  /// sessions"* — a browser that is running, listening, and undrivable. A
  /// session leaked this way survives until the browser is killed.
  public func close() async {
    if socket != nil {
      // Best effort: if the socket is already gone there is nothing to end, and
      // failing here would mask whatever actually went wrong first.
      _ = try? await send("session.end", [:])
    }
    socket?.cancel()
    socket = nil
    contextID = nil
    // The tab itself stays open — it holds the result of the task.
    agentTabID = nil
  }

  private func openSocket() async throws {
    socket = try makeTransport(port)
  }

  /// The top-level browsing context — the tab the agent drives.
  ///
  /// **Prefers a tab with a page in it.** `getTree` returns contexts in no
  /// order anyone should rely on, and taking the first one meant the agent
  /// could attach to a blank tab while the page the user actually had open sat
  /// beside it — which looks exactly like "it opened a new empty window" and
  /// produces a step with no candidates at all.
  ///
  /// A blank context is still returned when it is all there is, because a
  /// browser with one empty tab is a browser the agent can navigate.
  private func resolveContext() async throws -> String {
    let tree = try await send("browsingContext.getTree", [:])
    guard let contexts = tree["contexts"] as? [[String: Any]], !contexts.isEmpty else {
      throw BiDiError.noBrowsingContext
    }
    // A loaded tab, and where there is a choice, one in a named container.
    //
    // **Containers are separate cookie jars, and `default` is where automation
    // lands.** Firefox calls them containers, Zen calls them workspaces; a
    // person who organises their browsing into them is signed in *there*, and
    // a tab opened in `default` is a stranger in the same browser. Measured:
    // their Instagram sat logged in under user context `5f26d6ed…` while the
    // agent's tab in `default` was served the login page — which reads exactly
    // like "you are not logged in", and they were.
    //
    // The assumption, stated plainly: when named containers are in use, the
    // user's real session is in one of them rather than in `default`. A
    // browser with no containers has every tab in `default` and is unaffected.
    // With several named containers this picks the first with a page loaded,
    // which is a guess — the protocol exposes no notion of which tab the
    // person is looking at.
    let loaded = contexts.filter { context in
      guard let url = context["url"] as? String else { return false }
      return !Self.isBlank(url) && !Self.isPrivileged(url)
    }
    let chosen =
      loaded.first(where: { ($0["userContext"] as? String).map { $0 != "default" } ?? false })
      ?? loaded.first
      ?? contexts.first
    guard let id = chosen?["context"] as? String else {
      throw BiDiError.noBrowsingContext
    }
    // **Remember which container that tab is in.** Firefox containers — Zen
    // calls them workspaces — each have their own cookie jar, so a tab opened
    // in `default` is signed out of everything the user is signed in to
    // elsewhere. Measured: their Instagram sat logged in under user context
    // `5f26d6ed…` while the agent's tab, created in `default`, was served the
    // login page. It read exactly like "you are not logged in", and they were.
    userContextID = chosen?["userContext"] as? String
    return id
  }

  /// Whether a URL means "nothing is open here".
  ///
  /// `about:blank` is what a freshly created context reports; `about:newtab`
  /// and Zen's own start page are what a browser with no restored session
  /// shows. None of them carry anything to act on.
  static func isBlank(_ url: String) -> Bool {
    url.isEmpty || url == "about:blank" || url.hasPrefix("about:newtab")
      || url.hasPrefix("about:home") || url.hasPrefix("chrome://")
  }

  /// Whether the agent can run script in a context showing this URL.
  ///
  /// **An extension page is a privileged context, and every `script.evaluate`
  /// against one fails.** Observed: a tab suspender had parked a real page
  /// behind `moz-extension://…/suspended.html`, that tab sat in a named
  /// container, and the container preference in `resolveContext` therefore
  /// chose it over everything else. The run died on its first observation with
  /// *"System access is required. Start Zen with -remote-allow-system-access"*
  /// — a message about a launch flag, for a problem that was a choice of tab.
  ///
  /// `about:blank` is not in here on purpose. It is an ordinary content
  /// context that scripts run in perfectly well, and it is a valid tab to open
  /// from — a new tab inherits its container, which is how the agent lands in
  /// the jar the user is signed in to. What cannot be scripted is the
  /// browser's own surfaces and an add-on's.
  static func isPrivileged(_ url: String) -> Bool {
    url.hasPrefix("moz-extension:") || url.hasPrefix("chrome:")
      || url.hasPrefix("resource:") || url.hasPrefix("view-source:")
      || (url.hasPrefix("about:") && url != "about:blank")
  }

  public func context() throws -> String {
    guard let contextID else { throw BiDiError.noBrowsingContext }
    return contextID
  }

  // MARK: - Commands

  /// Sends one command and returns its `result`, draining events until the
  /// matching id arrives.
  @discardableResult
  func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    guard let socket else { throw BiDiError.disconnected }

    let id = nextID
    nextID += 1
    let payload: [String: Any] = ["id": id, "method": method, "params": params]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try await socket.send(String(decoding: data, as: UTF8.self))

    // BiDi multiplexes events onto the same socket. Anything without our id is
    // an event; drop it rather than mistaking it for a reply.
    while true {
      let text = try await socket.receive()
      guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      else { continue }
      guard let replyID = object["id"] as? Int, replyID == id else { continue }

      if (object["type"] as? String) == "error" {
        throw BiDiError.command(
          method: method,
          message: (object["message"] as? String) ?? "unknown error"
        )
      }
      return (object["result"] as? [String: Any]) ?? [:]
    }
  }

  // MARK: - Script

  /// Evaluates an expression in the page and returns its value as JSON.
  ///
  /// Returns `Data` rather than `[String: Any]` because a dictionary of `Any`
  /// is not `Sendable` and cannot cross an actor boundary. Re-serialising once
  /// here is cheaper than the alternative — a `Codable` type for every shape
  /// BiDi's tagged encoding can produce.
  ///
  /// `resultOwnership: "none"` and `awaitPromise: true` — the snapshot is
  /// synchronous, but a page that has patched a getter into a promise should
  /// not hang the step.
  public func evaluate(_ expression: String) async throws -> Data {
    let result = try await send(
      "script.evaluate",
      [
        "expression": expression,
        "target": ["context": try context()],
        "awaitPromise": true,
        "resultOwnership": "none",
        "serializationOptions": ["maxObjectDepth": 12, "maxDomDepth": 0],
      ]
    )

    if let exception = result["exceptionDetails"] as? [String: Any] {
      let text = (exception["text"] as? String) ?? "\(exception)"
      throw BiDiError.scriptFailed(text)
    }
    guard let value = result["result"] as? [String: Any] else {
      throw BiDiError.malformedResponse("no result in script.evaluate")
    }
    let plain = BiDiValue.plain(value) ?? [:]
    guard JSONSerialization.isValidJSONObject(plain) else {
      throw BiDiError.malformedResponse("script returned a non-JSON value")
    }
    return try JSONSerialization.data(withJSONObject: plain)
  }

  /// Navigates — in the tab already showing that site, when there is one.
  ///
  /// **The agent does not take over the tab you are reading, and it does not
  /// open a second copy of the tab you already have.** Navigating whichever
  /// context `getTree` returned replaced the page the user had open, with no
  /// way back but history. Opening a fresh tab regardless went the other way:
  /// a browser already showing Instagram got a second Instagram, every run.
  ///
  /// A person given this task uses the window they already have open, and opens
  /// one only if they have none. So does this — `tab(for:)`.
  public func navigate(to url: String) async throws {
    let target = try await tab(for: url)
    try await send(
      "browsingContext.navigate",
      ["context": target, "url": url, "wait": "complete"]
    )
  }

  /// The tab this run works in, created on first use and reused after.
  ///
  /// Once per session, not once per navigation: a multi-step task that visits
  /// three pages is still one piece of work, and scattering a tab per step is
  /// the other way to make a mess of someone's browser.
  ///
  /// Everything after this points at that tab — `contextID` moves — so
  /// observation, clicks and typing all act on the page the agent put there
  /// rather than on whatever the user has in front of them.
  ///
  /// The tab is left open when the run ends. The result of the task is in it,
  /// and closing it would take that away the moment it became useful.
  /// Opens the tab this run works in, and makes everything point at it.
  ///
  /// **Called before the first observation, not lazily on the first
  /// navigation.** Observing whatever tab happened to be open meant judging the
  /// task against a page that had nothing to do with it — measured: a leftover
  /// Instagram login tab from an earlier run produced `blocked 0.91` at step 0,
  /// before the agent had navigated anywhere or done anything at all.
  /// - Parameter creating: whether a tab may be opened when none is showing
  ///   the site. True for a plan with a `navigate` step, which is about to
  ///   load the page. **False everywhere else** — a blank tab nothing will
  ///   fill is not the site that was asked for, and acting on it reads as an
  ///   answer about that site. Measured: a scroll-only plan named
  ///   `facebook.com`, got a fresh `about:blank`, scrolled it nine times and
  ///   scored `progressed 0.15` with nothing wrong in any log.
  public func tab(for url: String? = nil, creating: Bool = true) async throws -> String {
    let contexts = try await topLevelContexts()

    // Once this run has a tab, it keeps it. Re-deciding every step is how an
    // agent ends up hopping between two tabs on the same site.
    if let agentTabID, contexts.contains(where: { $0.id == agentTabID }) {
      return agentTabID
    }

    // Who opened each tab, asked once. Everything below is a preference over
    // this list, and each answer costs a round trip.
    var mine: [TabContext] = []
    var theirs: [TabContext] = []
    for context in contexts {
      if await name(of: context.id) == Self.tabName {
        mine.append(context)
      } else {
        theirs.append(context)
      }
    }
    // The cookie jars the user actually browses in. `default` is where
    // automation lands and where nobody is signed in to anything.
    let jars = Set(theirs.compactMap { $0.userContext }.filter { $0 != "default" })


    // 1. The tab already showing this site. This is the one the user means by
    //    "I already have Instagram open".
    //
    //    **Theirs, not ours, when there is a choice.** Containers — Zen calls
    //    them workspaces — are separate cookie jars. Measured: the user's X tab
    //    sat signed in under container `8c0e920f…` while the agent's own x.com
    //    tab, opened in `default`, was served the login page — and the run
    //    reported `blocked` against an account that was logged in the whole
    //    time, one tab away.
    if let host = Self.host(of: url) {
      let onHost = theirs.filter { Self.host(of: $0.url) == host }
        + mine.filter { Self.host(of: $0.url) == host }
      if let existing = onHost.first {
        Log.info("using the tab already on \(host)")
        return await adopt(existing)
      }
    }

    // A site was named, no tab is showing it, and nothing is coming to load
    // one. **Stop here rather than falling through to preference 2**, which
    // asks a different question — "did this agent open a tab before" — and
    // answers it without reference to the site. Measured: a run navigated the
    // agent's tab from Facebook to a GitHub issues page, and the next
    // `observe --url facebook.com` adopted that same tab and reported the
    // issues list, confidently, as the answer about Facebook. An agent tab on
    // another site is still another site.
    //
    // With a navigation coming this is the right preference and is left
    // alone: the step is about to load the named site into that tab, which is
    // how a run reuses its own tab instead of piling up new ones.
    if !creating, let url { throw BiDiError.noTabOnSite(url) }

    // 2. A tab this agent opened before, found by window name rather than by
    //    id — BiDi context ids are not stable across sessions, so the id a run
    //    writes down is not the id its own resume sees for the same tab.
    //
    //    Scanned across every context, not looked up through `window.open`:
    //    named targeting only searches contexts the opener is familiar with, so
    //    a run that resolved to an unrelated tab could not see its own tab and
    //    opened another one. Measured — a blank tab per invocation.
    //
    //    **Unless it is in the wrong jar.** An agent tab parked in `default`
    //    while every session the user has lives in a workspace container is
    //    signed out of everything, and reusing it is how the next task reports
    //    a login wall on a site they are logged in to. A tab like that is not
    //    worth keeping, so it is closed rather than left to confuse them.
    for context in mine {
      if (context.userContext ?? "default") != "default" || jars.isEmpty {
        Log.info("re-using the agent tab from an earlier run")
        return await adopt(context)
      }
      Log.info("closing an agent tab left in the default container")
      _ = try? await send("browsingContext.close", ["context": context.id])
    }

    // 3. Nothing to reuse. Open one — but only when a navigation is about to
    //    fill it, so a blank tab is never left behind for its own sake.
    guard let url else { return try context() }

    // Opened from the tab the user is looking at, so it lands in the workspace
    // their sessions live in. Otherwise it inherits whichever container
    // `getTree` happened to hand back, and a tab in the wrong jar is a tab
    // that is signed out of everything — which reads as "the agent logged me
    // out" and is the single most alarming thing it can do.
    //
    // Their tab, never the agent's: ours may be parked in `default`, and a tab
    // opened from it inherits that empty jar.
    // Not an add-on's page. Opening from one inherits its privileged context,
    // so the new tab is as unscriptable as the one it came from.
    let openable = theirs.filter { !Self.isPrivileged($0.url) }
    let opener =
      await visible(among: openable)
      ?? openable.first(where: { ($0.userContext ?? "default") != "default" })
      ?? openable.first

    // **Nothing loaded can say where the user browses.** This is the state the
    // agent leaves behind every time it relaunches the browser to get the debug
    // port: tabs restored but not *loaded*, so `getTree` is nearly empty.
    // Opening from what is left puts the tab in `default` and shows the user a
    // login page for an account they are signed in to.
    //
    // Remembering the container from a previous run was tried and cannot work:
    // these ids are per-session. The same four containers came back as
    // `8c0e920f…, aabd5dbe…, e804e1bf…, 693a46d5…` before a restart and
    // `1ef8908b…, 590015db…, 8018f1f3…, 92fe77e0…` after it.
    //
    // The cookies are the evidence, and they do survive. A jar that already
    // holds this site's cookies is the jar the user is signed in to, and no tab
    // has to be loaded to ask.
    if let jar = await jarHoldingCookies(for: url),
      jar != (opener?.userContext ?? "default")
    {
      Log.info("opening a tab in the container that holds this site's cookies")
      return try await createTab(inContainer: jar)
    }

    if let opener {
      contextID = opener.id
      userContextID = opener.userContext
    }

    // **A named window.** `window.open(url, name)` returns the existing tab
    // with that name if there is one, and opens it if there is not — so every
    // invocation lands in the same tab without anything having to remember an
    // id between processes.
    //
    // Remembering the id was tried and cannot work: BiDi context ids are not
    // stable across sessions, so the id written by one run is not the id the
    // next run sees for the same tab. Measured — the tab count kept climbing
    // while `getTree` never contained the remembered id.
    //
    // Opened by the page rather than `browsingContext.create`, because a tab
    // from `create` belongs to the session that made it and goes away when that
    // session ends. This one is an ordinary browser tab, and it inherits the
    // opener's container, which is the one the user is signed in to.
    //
    // `userActivation` is required: a pop-up with no gesture behind it is
    // blocked, and the block is silent.
    let result = try await send(
      "script.evaluate",
      [
        "expression": "window.open('about:blank', '\(Self.tabName)')",
        "target": ["context": try context()],
        "awaitPromise": false,
        "resultOwnership": "none",
        "userActivation": true,
      ]
    )
    if let exception = result["exceptionDetails"] as? [String: Any] {
      throw BiDiError.scriptFailed("\(exception["text"] ?? exception)")
    }
    // A WindowProxy carries the id of the context it refers to, whether that
    // tab was just opened or was already there under this name.
    guard let value = result["result"] as? [String: Any],
      let window = value["value"] as? [String: Any],
      let id = window["context"] as? String
    else {
      throw BiDiError.noBrowsingContext
    }

    agentTabID = id
    contextID = id
    _ = try? await send("browsingContext.activate", ["context": id])
    Log.debug("agent tab \(id) in container \(userContextID ?? "default")")
    return id
  }

  /// Every cookie jar this browser has.
  private func containers() async -> Set<String> {
    guard let jars = try? await send("browser.getUserContexts", [:]),
      let list = jars["userContexts"] as? [[String: Any]]
    else { return [] }
    return Set(list.compactMap { $0["userContext"] as? String })
  }

  /// Whether a cookie on `domain` is sent to `host`.
  ///
  /// **`storage.getCookies`' own domain filter is an exact string match, and
  /// almost no site stores cookies under the name you navigate to.** Facebook
  /// keeps its session on `.facebook.com`; asking for `facebook.com` returned
  /// nothing at all, in every jar, while a raw scan of the same jar found ten
  /// cookies including `c_user`. Measured across three sites: the filter found
  /// 0 of 10 for facebook.com, 0 of 17 for instagram.com, and 3 of 15 for
  /// x.com — x.com only because X happens to store cookies on the bare name.
  ///
  /// That single mismatch is why signing in made no difference anywhere but X.
  /// The lookup found no jar, the agent fell back to opening from whatever tab
  /// was on screen, and that tab was in whichever jar the user last used —
  /// usually the default one, which is signed in to nothing.
  ///
  /// So the match is done here, the way cookies are actually scoped: a leading
  /// dot is not part of the name, and a cookie set on a parent domain reaches
  /// its subdomains.
  static func cookieReaches(host: String, domain: String) -> Bool {
    let scope = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    guard !scope.isEmpty, !host.isEmpty else { return false }
    // The suffix rules need a dot on the side doing the containing, or a
    // cookie scoped to a bare `com` would reach every site on it. Browsers
    // refuse such a cookie, but this should not depend on that.
    return host == scope
      || (scope.contains(".") && host.hasSuffix("." + scope))
      || (host.contains(".") && scope.hasSuffix("." + host))
  }

  /// The container that already holds this site's cookies.
  ///
  /// Containers are separate cookie jars, so "where is the user signed in to
  /// this site" has a direct answer that needs no tab loaded, no guess, and
  /// nothing remembered between runs: ask each jar what it holds, and match
  /// the host against it here rather than trusting the protocol's filter.
  ///
  /// **Counting cookies picks the jar with the most analytics in it.**
  /// Measured on Slack, where two containers are signed in to different
  /// workspaces: 21 cookies against 16, and the extra five were `_ga`,
  /// `_cs_c`, `_cs_id`, `cjConsent` and `PageCount`. Ranking on that is
  /// ranking on how much a site tracked you.
  ///
  /// `httpOnly` is the better half of the same idea and costs nothing extra: a
  /// session cookie is set by the server and hidden from scripts, while the
  /// analytics that inflate the count are written by scripts and cannot be.
  /// Measured across this profile — Facebook's signed-out jar holds 3 of them
  /// against 7 where the session is, X holds 2 against 7, and the jar with
  /// `auth_token` and `xs` in it wins both times.
  ///
  /// Total count still breaks ties, because it is the older signal and is
  /// right more often than a coin.
  private func jarHoldingCookies(for url: String?) async -> String? {
    guard let host = Self.host(of: url) else { return nil }
    var scored: [(jar: String, session: Int, total: Int)] = []
    // **`default` is a jar like any other.** Excluding it meant a site the user
    // signed in to without opening a container could never be found, and the
    // one jar most people use most was the one jar never looked in.
    for jar in await containers().sorted() {
      guard
        let result = try? await send(
          "storage.getCookies",
          ["partition": ["type": "storageKey", "userContext": jar]]),
        let cookies = result["cookies"] as? [[String: Any]]
      else { continue }
      let mine = cookies.filter {
        guard let domain = $0["domain"] as? String else { return false }
        return Self.cookieReaches(host: host, domain: domain)
      }
      guard !mine.isEmpty else { continue }
      let session = mine.filter { ($0["httpOnly"] as? Bool) == true }.count
      Log.debug("\(jar) holds \(mine.count) cookies for \(host), \(session) of them httpOnly")
      scored.append((jar, session, mine.count))
    }

    guard
      let best = scored.max(by: { ($0.session, $0.total) < ($1.session, $1.total) })
    else { return nil }

    // **More than one signed-in container is a question, not a ranking.** Two
    // Slack workspaces both hold `d`, `d-s` and `ui`, so nothing in the jars
    // says which account the task meant. Something has to be chosen or no tab
    // can be opened at all, but choosing quietly is how a task succeeds in the
    // wrong account — so it is said out loud instead.
    let rivals = scored.filter { $0.jar != best.jar && $0.session == best.session }
    if !rivals.isEmpty {
      Log.warn(
        "signed in to \(host) in \(rivals.count + 1) containers; "
          + "using \(best.jar) — if this is the wrong account, that is why")
    } else {
      Log.info("\(host) is signed in where \(best.session) of its session cookies are")
    }
    return best.jar
  }

  /// A new tab in a named container.
  ///
  /// `window.open` cannot choose a container — it inherits its opener's — so
  /// this is the only way to put a tab in a jar when no tab of the user's is
  /// loaded to open it from.
  private func createTab(inContainer container: String) async throws -> String {
    let result = try await send(
      "browsingContext.create", ["type": "tab", "userContext": container])
    guard let id = result["context"] as? String else { throw BiDiError.noBrowsingContext }
    agentTabID = id
    contextID = id
    userContextID = container
    // Named here rather than by `window.open`, so a later run still recognises
    // it as the agent's own.
    _ = try? await send(
      "script.evaluate",
      [
        "expression": "window.name = '\(Self.tabName)'",
        "target": ["context": id],
        "awaitPromise": false,
        "resultOwnership": "none",
      ])
    _ = try? await send("browsingContext.activate", ["context": id])
    return id
  }

  /// Every tab, with the three things that decide which one the agent works
  /// in: the container it lives in, whether the agent opened it, and whether
  /// it is the one on screen.
  ///
  /// Three separate bugs in this file were all "which tab, and why", and each
  /// took a screenshot and a guess to find. This answers it in one call.
  public func inventory(cookiesFor url: String? = nil) async throws -> [String] {
    var rows: [String] = []
    // Which cookie jars exist at all. A browser with one container cannot be
    // signed in "somewhere else", and that is worth knowing before blaming
    // containers for a login page.
    rows.append("containers: " + (await containers()).sorted().joined(separator: ", "))
    if let url, let host = Self.host(of: url) {
      // Per jar, not a verdict. The old line printed "nowhere but default"
      // whenever the lookup came back empty, which read as a finding about the
      // default jar when nothing had looked in it — and the lookup was empty
      // for every site but X, so the diagnostic agreed with the bug.
      for jar in await containers().sorted() {
        guard
          let result = try? await send(
            "storage.getCookies",
            ["partition": ["type": "storageKey", "userContext": jar]]),
          let cookies = result["cookies"] as? [[String: Any]]
        else {
          rows.append("  \(jar): unreadable")
          continue
        }
        let mine = cookies.filter {
          guard let domain = $0["domain"] as? String else { return false }
          return Self.cookieReaches(host: host, domain: domain)
        }
        rows.append("  \(jar): \(mine.count) cookies for \(host)")
      }
      let chosen = await jarHoldingCookies(for: url)
      rows.append("\(host) would be opened in: \(chosen ?? "the tab on screen")")
    }

    for context in try await topLevelContexts() {
      let owner = await name(of: context.id) == Self.tabName ? "agent" : "user "
      let onScreen = await string("document.visibilityState", in: context.id) == "visible"
      rows.append(
        "\(onScreen ? "▸" : " ") \(owner)  "
          + "\((context.userContext ?? "default").padding(toLength: 10, withPad: " ", startingAt: 0))  "
          + context.url)
    }
    return rows
  }

  /// One top-level tab, as `browsingContext.getTree` describes it.
  struct TabContext: Sendable {
    let id: String
    let url: String
    let userContext: String?
  }

  /// Every tab the browser has, ignoring frames inside them.
  private func topLevelContexts() async throws -> [TabContext] {
    let tree = try await send("browsingContext.getTree", [:])
    guard let contexts = tree["contexts"] as? [[String: Any]] else { return [] }
    return contexts.compactMap { raw in
      guard let id = raw["context"] as? String else { return nil }
      return TabContext(
        id: id,
        url: (raw["url"] as? String) ?? "",
        userContext: raw["userContext"] as? String
      )
    }
  }

  /// The host a URL names, with `www.` dropped so one spelling matches another.
  ///
  /// Host rather than full URL: the user's open Instagram tab is sitting on a
  /// thread, and the task navigates to the inbox. Same tab, same session, and
  /// requiring the URLs to be equal would open a second one.
  static func host(of url: String?) -> String? {
    guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// Makes this tab the one the run works in, and brings it to the front.
  ///
  /// An adopted tab is deliberately **not** renamed. `window.name` is how the
  /// agent recognises a tab it opened itself, and stamping it on the user's tab
  /// would make the next run mistake theirs for its own — which is the thing
  /// that has to stay distinguishable, because only one of the two is signed in.
  private func adopt(_ context: TabContext) async -> String {
    agentTabID = context.id
    contextID = context.id
    userContextID = context.userContext
    _ = try? await send("browsingContext.activate", ["context": context.id])
    Log.debug("working in tab \(context.id) in container \(userContextID ?? "default")")
    return context.id
  }

  /// What a tab calls its own window.
  private func name(of context: String) async -> String {
    await string("window.name", in: context)
  }

  /// The tab the user is actually looking at.
  ///
  /// **A new tab opens where you are.** `window.open` inherits its opener's
  /// container, and containers — Zen calls them workspaces — are separate
  /// cookie jars. Opening from whichever context `getTree` happened to return
  /// put the agent's tab in a jar the user was never signed in to: X served it
  /// the login page while their own X tab, in the workspace they were looking
  /// at, was signed in the whole time.
  ///
  /// `document.visibilityState` is the only thing in the protocol that knows
  /// which tab that is — BiDi reports no active tab, and `getTree` order means
  /// nothing.
  private func visible(among contexts: [TabContext]) async -> TabContext? {
    for context in contexts {
      if await string("document.visibilityState", in: context.id) == "visible" {
        return context
      }
    }
    return nil
  }

  /// One expression, one string, no throwing. A context that cannot answer is
  /// a context this was asking about, not an error worth failing the run over.
  private func string(_ expression: String, in context: String) async -> String {
    guard
      let result = try? await send(
        "script.evaluate",
        [
          "expression": expression,
          "target": ["context": context],
          "awaitPromise": false,
          "resultOwnership": "none",
        ]),
      let value = result["result"] as? [String: Any]
    else { return "" }
    return (value["value"] as? String) ?? ""
  }

  /// The window name the agent's tab answers to.
  ///
  /// The whole mechanism for keeping one tab across separate processes. It is
  /// distinctive on purpose: `window.open` with a name a page also uses would
  /// hand the agent that page's popup.
  static let tabName = "__open_agent_tab"

  /// How many nodes the browser itself reports for an accessibility role.
  ///
  /// `browsingContext.locateNodes` with an accessibility locator asks the
  /// browser for its *computed* role, which is the thing a DOM selector cannot
  /// know: a `div` that Instagram wires up as a button has no `role="button"`
  /// attribute and no `<button>` tag, and only the accessibility layer calls it
  /// a button.
  public func locateByRole(_ role: String) async throws -> Int {
    let result = try await send(
      "browsingContext.locateNodes",
      [
        "context": try context(),
        "locator": ["type": "accessibility", "value": ["role": role]],
      ]
    )
    return ((result["nodes"] as? [Any]) ?? []).count
  }

  /// One raw located node, for inspecting the shape BiDi returns.
  public func locateRaw(_ role: String) async throws -> String {
    let result = try await send(
      "browsingContext.locateNodes",
      [
        "context": try context(),
        "locator": ["type": "accessibility", "value": ["role": role]],
      ]
    )
    guard let first = (result["nodes"] as? [Any])?.first,
      let data = try? JSONSerialization.data(withJSONObject: first),
      let text = String(data: data, encoding: .utf8)
    else { return "none" }
    return text
  }

  /// Dispatches real input events.
  ///
  /// `input.performActions`, not a synthetic `value` assignment: assigning
  /// `value` does not fire the listeners modern web applications depend on, so
  /// the field updates on screen and the application never learns about it.
  public func performActions(_ actions: [[String: Any]]) async throws {
    try await send(
      "input.performActions",
      ["context": try context(), "actions": actions]
    )
  }
}

/// Unwraps BiDi's tagged value encoding into plain Swift values.
///
/// BiDi does not send JSON; it sends `{"type":"string","value":"x"}` and
/// `{"type":"object","value":[[k, v], …]}`. Decoding that with `Codable` means
/// a type for every shape, so it is unwrapped once here instead.
enum BiDiValue {
  static func plain(_ node: Any) -> Any? {
    guard let node = node as? [String: Any], let type = node["type"] as? String else {
      return node
    }
    switch type {
    case "undefined", "null": return nil
    case "string", "boolean": return node["value"]
    case "number":
      // BiDi sends Infinity, -Infinity and NaN as STRINGS. `Double("Infinity")`
      // succeeds in Swift, so parsing them would put a non-finite value into a
      // `CGRect` — and an infinitely wide rect passes every `width >= 1` check
      // there is, producing a candidate that cannot be clicked and cannot be
      // filtered out. Keeping them as strings makes the action fail to decode,
      // which drops it. That is the correct failure.
      if let d = node["value"] as? Double { return d.isFinite ? d : "\(d)" }
      if let s = node["value"] as? String { return s }
      return node["value"]
    case "array", "set":
      return (node["value"] as? [Any])?.compactMap(plain)
    case "object", "map":
      guard let pairs = node["value"] as? [[Any]] else { return [:] }
      var out: [String: Any] = [:]
      for pair in pairs where pair.count == 2 {
        let key = (plain(pair[0]) as? String) ?? "\(pair[0])"
        if let value = plain(pair[1]) { out[key] = value }
      }
      return out
    default:
      return node["value"]
    }
  }
}
