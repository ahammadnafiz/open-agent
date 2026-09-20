import Foundation

/// Errors from the WebDriver BiDi transport.
public enum BiDiError: Error, Equatable, Sendable {
  /// The browser never opened its debug port. Cold start is 5–7 s measured, so
  /// this is a connect-retry ceiling rather than a sleep — a fixed sleep either
  /// wastes time or races.
  case notListening(port: Int)
  case handshakeFailed(String)
  /// The browser answered, but with an error for this command.
  case command(method: String, message: String)
  case noBrowsingContext
  case malformedResponse(String)
  case disconnected
  /// The snapshot script threw inside the page.
  case scriptFailed(String)
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
  private var socket: URLSessionWebSocketTask?
  private let session: URLSession
  private var nextID = 1
  private var contextID: String?

  public init(port: Int = Constants.Browser.bidiPort) {
    self.port = port
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Constants.Jev.requestTimeout.inSeconds
    session = URLSession(configuration: configuration)
  }

  // MARK: - Lifecycle

  /// Connects and creates a session, retrying while the browser starts.
  ///
  /// Cold start was measured at 5–7 s, so this polls up to
  /// `Constants.Browser.launchTimeout` rather than sleeping a fixed amount.
  public func connect() async throws {
    let deadline = ContinuousClock.now + Constants.Browser.launchTimeout
    var lastError: (any Error)?

    while ContinuousClock.now < deadline {
      do {
        try await openSocket()

        // `session.new` fails when a session already exists — which is the
        // normal case for a browser this agent started earlier and left
        // running. That is not a connection failure, so it is not treated as
        // one: what actually decides whether we can drive the browser is
        // whether `browsingContext.getTree` answers.
        do {
          _ = try await send("session.new", ["capabilities": [:] as [String: Sendable]])
        } catch let error as BiDiError {
          Log.debug("bidi session.new declined (\(error)); reusing the existing session")
        }

        contextID = try await resolveContext()
        Log.debug("bidi connected on port \(port), context \(contextID ?? "-")")
        return
      } catch {
        lastError = error
        // A half-open socket left behind here is what leaks the session, so the
        // retry path tears it down the same way `close()` does.
        if socket != nil { _ = try? await send("session.end", [:]) }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        try? await Task.sleep(for: .milliseconds(300))
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
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    contextID = nil
  }

  private func openSocket() async throws {
    guard let url = URL(string: "ws://127.0.0.1:\(port)/session") else {
      throw BiDiError.handshakeFailed("bad url")
    }
    let task = session.webSocketTask(with: url)
    task.resume()
    socket = task
  }

  /// The top-level browsing context — the tab the agent drives.
  private func resolveContext() async throws -> String {
    let tree = try await send("browsingContext.getTree", [:])
    guard let contexts = tree["contexts"] as? [[String: Any]],
      let first = contexts.first,
      let id = first["context"] as? String
    else {
      throw BiDiError.noBrowsingContext
    }
    return id
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
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))

    // BiDi multiplexes events onto the same socket. Anything without our id is
    // an event; drop it rather than mistaking it for a reply.
    while true {
      let message = try await socket.receive()
      let text: String
      switch message {
      case .string(let s): text = s
      case .data(let d): text = String(decoding: d, as: UTF8.self)
      @unknown default: throw BiDiError.malformedResponse("unknown frame")
      }

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

  public func navigate(to url: String) async throws {
    try await send(
      "browsingContext.navigate",
      ["context": try context(), "url": url, "wait": "complete"]
    )
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
