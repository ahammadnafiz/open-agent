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

  /// A session created by an earlier process is not ours to reuse, but it is
  /// also not a connection failure. What decides whether the browser is
  /// drivable is whether `browsingContext.getTree` answers.
  @Test("session.new being refused is not fatal on its own")
  func sessionNewRefusalIsTolerated() async throws {
    let transport = FakeBiDiTransport(replies: [
      err(1, "Maximum number of active sessions"),
      ok(2, oneContext),
    ])
    let client = BiDiClient(port: 9333, makeTransport: { _ in transport })
    try await client.connect()
    #expect(try await client.context() == "ctx-1")
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
