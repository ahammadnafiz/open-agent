import Foundation
import Testing

@testable import Harness

@Suite("JevClient")
struct JevClientTests {

  @Test("happy path decodes a full batch into raw probabilities")
  func happyPath() async throws {
    let transport = FakeTransport([
      .init(status: 200, body: Fixture.fullBatch(), headers: ["x-typesafe-request-id": "req_abc"])
    ])
    let verdict = try await Fixture.client(transport).step(Fixture.context())

    #expect(verdict.progressed == 0.97)
    #expect(verdict.unchanged == 0.03)
    #expect(verdict.blocked == 0.04)
    #expect(verdict.taskDone == 0.05)
    #expect(verdict.looping == 0.05)
    #expect(verdict.sufficient == 0.93)
    #expect(verdict.target?.choice == "e0")
    #expect(verdict.modelVersion == Constants.Models.jev)
    #expect(verdict.requestID == "req_abc")
    #expect(await transport.callCount == 1)
  }

  /// `riskMax` is `max`, never a mean. One confident red flag must win.
  @Test("riskMax takes the maximum, not the mean")
  func riskMaxIsMax() async throws {
    let transport = FakeTransport([.init(status: 200, body: Fixture.fullBatch())])
    let verdict = try await Fixture.client(transport).step(Fixture.context())
    // 0.02, 0.11, 0.01 — a mean would be 0.047 and would bury the 0.11.
    #expect(verdict.riskMax == 0.11)
  }

  /// `wrong_context` is skipped when the task names no instance. Asking about
  /// a context the task never named invents one.
  @Test("wrong_context is absent unless task_context is set")
  func wrongContextOnlyWhenNamed() async throws {
    let without = FakeTransport([.init(status: 200, body: Fixture.fullBatch())])
    let a = try await Fixture.client(without).step(Fixture.context())
    #expect(a.wrongContext == nil)

    let with = FakeTransport([
      .init(status: 200, body: Fixture.fullBatch(includeWrongContext: true))
    ])
    let b = try await Fixture.client(with).step(
      Fixture.context(taskContext: "the x.com account @ahammad_nafiz")
    )
    #expect(b.wrongContext == 0.08)
  }

  @Test("the batch omits the Choice when there are no candidates")
  func noCandidatesOmitsChoice() {
    let q = Batteries.step(candidates: [:], includeWrongContext: false)
    #expect(q[Batteries.ID.target] == nil)
    // Verification still rides along — the loop needs it to tell "blocked"
    // from "done" from "merely empty".
    #expect(q[Batteries.ID.blocked] != nil)
    #expect(q[Batteries.ID.taskDone] != nil)
  }

  // MARK: - Errors

  /// 401 is never retried. A second request with the same key gets the same
  /// answer, and the retry burns the step deadline to learn nothing.
  @Test("401 is not retried")
  func unauthorizedNotRetried() async throws {
    let transport = FakeTransport([
      .init(status: 401, body: Data(#"{"detail":"Missing or invalid API key"}"#.utf8))
    ])
    await #expect(throws: JevError.unauthorized) {
      try await Fixture.client(transport).step(Fixture.context())
    }
    #expect(await transport.callCount == 1)
  }

  @Test("400 and 422 are not retried — they are our bug", arguments: [400, 422])
  func clientErrorsNotRetried(status: Int) async throws {
    let transport = FakeTransport([
      .init(status: status, body: Data(#"{"detail":"Too many choices."}"#.utf8))
    ])
    await #expect(throws: (any Error).self) {
      try await Fixture.client(transport).step(Fixture.context())
    }
    #expect(await transport.callCount == 1)
  }

  @Test("429 retries and then succeeds")
  func rateLimitedThenSuccess() async throws {
    let transport = FakeTransport([
      .init(status: 429, body: Data(), headers: ["retry-after": "1"]),
      .init(status: 200, body: Fixture.fullBatch()),
    ])
    let sleeps = SleepRecorder()
    let verdict = try await Fixture.client(transport, recordSleeps: { sleeps.record($0) })
      .step(Fixture.context())

    #expect(verdict.progressed == 0.97)
    #expect(await transport.callCount == 2)
    // Retry-After wins outright over computed backoff. Guessing shorter than
    // the server asked is how a 429 becomes a ban.
    #expect(sleeps.all == [.seconds(1)])
  }

  @Test("529 overloaded is retried")
  func overloadedRetried() async throws {
    let transport = FakeTransport([
      .init(status: 529, body: Data()),
      .init(status: 200, body: Fixture.fullBatch()),
    ])
    _ = try await Fixture.client(transport).step(Fixture.context())
    #expect(await transport.callCount == 2)
  }

  @Test("retries stop at maxRetries")
  func retriesExhausted() async throws {
    let transport = FakeTransport([
      .init(status: 500, body: Data()),
      .init(status: 500, body: Data()),
      .init(status: 500, body: Data()),
      .init(status: 500, body: Data()),
    ])
    await #expect(throws: JevError.server(status: 500)) {
      try await Fixture.client(transport).step(Fixture.context())
    }
    // 1 initial + Constants.Jev.maxRetries
    #expect(await transport.callCount == Constants.Jev.maxRetries + 1)
  }

  /// **The clamp.** With only 5 seconds of step budget left, a 10-second
  /// request timeout leaves no room for another attempt, so the client
  /// surfaces the real cause instead of being killed mid-retry by the step
  /// deadline and reporting a timeout.
  @Test("retries are clamped by the remaining step deadline")
  func retriesClampedByDeadline() async throws {
    let transport = FakeTransport([
      .init(status: 429, body: Data()),
      .init(status: 200, body: Fixture.fullBatch()),
    ])
    await #expect(throws: JevError.rateLimited(retryAfter: nil)) {
      try await Fixture.client(transport).step(Fixture.context(), budgetRemaining: .seconds(5))
    }
    #expect(await transport.callCount == 1, "no second attempt fits in the deadline")
  }

  @Test("an unknown answer type throws rather than being dropped")
  func unknownAnswerTypeThrows() async throws {
    let body = Data(
      #"""
      {"model":"jev-1.13.0","usage":{"input_tokens":1,"output_tokens":1},
       "answers":{"progressed":{"type":"quantum","value":0.5}}}
      """#.utf8)
    let transport = FakeTransport([.init(status: 200, body: body)])
    await #expect(throws: (any Error).self) {
      try await Fixture.client(transport).step(Fixture.context())
    }
    #expect(await transport.callCount == 1, "a schema mismatch is deterministic; never retried")
  }

  @Test("a missing required answer throws")
  func missingAnswerThrows() async throws {
    let body = Data(
      #"""
      {"model":"jev-1.13.0","usage":{"input_tokens":1,"output_tokens":1},
       "answers":{"progressed":{"type":"noul","noul":0.9}}}
      """#.utf8)
    let transport = FakeTransport([.init(status: 200, body: body)])
    await #expect(throws: (any Error).self) {
      try await Fixture.client(transport).step(Fixture.context())
    }
  }

  // MARK: - Preflight

  /// 256 options returns `400 {"detail":"Too many choices..."}`. Caught here so
  /// the failure names its own cause instead of arriving as an opaque 400 —
  /// and so the step escalates to vision rather than silently truncating.
  @Test("more than 255 candidates is refused before sending")
  func tooManyCandidatesRefusedLocally() async throws {
    let candidates = Dictionary(
      uniqueKeysWithValues: (0...Constants.Jev.maxCandidates).map { ("e\($0)", "Item \($0)") }
    )
    let transport = FakeTransport([])
    await #expect(throws: JevError.tooManyCandidates(count: 256, limit: 255)) {
      try await Fixture.client(transport).step(Fixture.context(candidates: candidates))
    }
    #expect(await transport.callCount == 0, "nothing is sent")
  }

  @Test("exactly 255 candidates is allowed")
  func exactly255IsFine() async throws {
    let candidates = Dictionary(
      uniqueKeysWithValues: (0..<Constants.Jev.maxCandidates).map { ("e\($0)", "Item \($0)") }
    )
    let transport = FakeTransport([.init(status: 200, body: Fixture.fullBatch())])
    _ = try await Fixture.client(transport).step(Fixture.context(candidates: candidates))
    #expect(await transport.callCount == 1)
  }

  @Test("an oversized state is refused before sending")
  func oversizedStateRefused() async throws {
    let huge = String(
      repeating: "x",
      count: Constants.Jev.stateTokenLimit * Constants.Jev.charactersPerTokenEstimate + 1_000)
    let context = StepContext(
      task: "t", planStep: .init(kind: "click", target: "x", payload: nil),
      lastAction: nil, screenBefore: huge, screenNow: "",
      recentHistory: [], candidates: ["e0": "A"]
    )
    let transport = FakeTransport([])
    await #expect(throws: (any Error).self) {
      try await Fixture.client(transport).step(context)
    }
    #expect(await transport.callCount == 0)
  }

  // MARK: - Secrets

  /// The vendor SDKs redact secret headers for you. This client is hand-rolled
  /// and gets nothing for free, so redaction is asserted rather than assumed.
  @Test("the API key never survives header rendering")
  func apiKeyIsRedacted() {
    let rendered = Log.redacted([
      "Authorization": "Bearer sk-live-must-never-appear",
      "Content-Type": "application/json",
    ])
    #expect(!rendered.contains("sk-live-must-never-appear"))
    #expect(rendered.contains("<redacted>"))
    #expect(rendered.contains("application/json"))
  }

  @Test("the key is sent as a Bearer token")
  func bearerHeader() async throws {
    let transport = FakeTransport([.init(status: 200, body: Fixture.fullBatch())])
    _ = try await Fixture.client(transport).step(Fixture.context())
    let sent = await transport.sentRequests.first
    #expect(
      sent?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-a-real-credential")
  }
}

/// Records the delays a client actually waited, so retry timing is assertable
/// without a real clock.
final class SleepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []
  func record(_ d: Duration) {
    lock.lock()
    recorded.append(d)
    lock.unlock()
  }
  var all: [Duration] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

/// Opening the connection before the first step needs it.
@Suite("The connection is warmed off the critical path")
struct ConnectionWarmingTests {

  /// **The trap this is guarding is dispatch, not behaviour.** `warm` has a
  /// do-nothing default so offline transports need not implement it, and a
  /// default supplied only in an extension would be the version every call
  /// through `any JevTransport` resolved to — statically, at compile time,
  /// with the real implementation never running. This codebase has shipped
  /// that bug twice, and both times the feature looked present and did
  /// nothing.
  @Test("warming reaches the transport, not the protocol default")
  func warmReachesTheTransport() async throws {
    let transport = FakeTransport([])
    let client = JevClient(apiKey: "test-key", transport: transport)

    await client.warm()

    let warmed = await transport.warmed
    #expect(warmed == [Constants.Jev.baseURL])
  }

  /// Warming is an optimisation, so it must not consume a scripted reply or
  /// otherwise count as a request. A step issued afterwards is still the
  /// first thing the transport is asked to send.
  @Test("warming does not count as a request")
  func warmingIsNotARequest() async throws {
    let transport = FakeTransport([])
    let client = JevClient(apiKey: "test-key", transport: transport)

    await client.warm()

    let sent = await transport.callCount
    #expect(sent == 0)
  }
}
