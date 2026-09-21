import Foundation

/// The HTTP layer, behind a seam.
///
/// Injected so every retry, status-mapping and decode branch is unit-testable
/// offline. The live path is `URLSessionTransport`; `swift test` never touches
/// the network — SPEC.md § Testing Strategy.
public protocol JevTransport: Sendable {
  func send(_ request: URLRequest, timeout: Duration) async throws -> (Data, HTTPURLResponse)

  /// Opens the connection before the first step needs it.
  ///
  /// **A protocol requirement, not only an extension member.** A method
  /// supplied just in an extension dispatches statically through
  /// `any JevTransport`, so the live transport's implementation would never be
  /// reached and this would be dead code that reads like a feature — a mistake
  /// this codebase has already made twice.
  func warm(_ baseURL: URL) async
}

extension JevTransport {
  /// Transports with no connection to open — the offline ones `swift test`
  /// uses — get this and do nothing.
  public func warm(_ baseURL: URL) async {}
}

/// The live transport. **Holds one `URLSession` for the process lifetime.**
///
/// Measured: 383 ms warm versus ~900 ms cold, because TLS and TCP setup to the
/// vendor's edge costs ~520 ms from this location. Reconnecting per step would
/// more than double step latency, and a session created per call throws the
/// warm connection away every time.
///
/// A session spans several `run`/`resume` invocations, which are separate
/// processes, so the warm connection dies between them — see `warm()`, which
/// is how that cost is paid somewhere other than the first step.
public final class URLSessionTransport: JevTransport {
  private let session: URLSession

  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = ["Content-Type": "application/json"]
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  /// Opens the connection before anything needs it.
  ///
  /// **Every invocation is a new process, so every invocation paid the cold
  /// handshake on the step the user was waiting for.** Measured: `judge` runs
  /// 1342–1410 ms on the first step of a run and 481–664 ms on every step
  /// after it, and the difference is TCP and TLS to the vendor's edge.
  ///
  /// It is entirely dead time that overlaps something else the agent has to do
  /// anyway — attaching to the browser, finding the right tab, reading the
  /// cookie jar — so it is started before that work and never waited on.
  ///
  /// The request carries **no credential**: it exists to open a socket, not to
  /// ask anything, and an unauthenticated response warms the pool exactly as
  /// well as an authorized one. Failure is not an error — if the network is
  /// down, the real call will say so with a real message.
  public func warm(_ baseURL: URL) async {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 5
    _ = try? await session.data(for: request)
  }

  public func send(_ request: URLRequest, timeout: Duration) async throws -> (Data, HTTPURLResponse)
  {
    var request = request
    request.timeoutInterval = timeout.inSeconds
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw JevError.malformedResponse(field: "response is not HTTP")
      }
      return (data, http)
    } catch let error as URLError {
      throw error.code == .timedOut
        ? JevError.timedOut : JevError.transport(code: error.code.rawValue)
    }
  }
}

/// Answers one step's battery.
///
/// A protocol so `LoopTests` can drive the loop from recorded verdicts with no
/// network and no API key — SPEC.md § Testing Strategy puts fixture-level tests
/// inside `swift test` and everything live in `Probe`.
public protocol StepJudge: Sendable {
  func step(_ context: StepContext, budgetRemaining: Duration) async throws -> StepVerdict
}

/// Calls Jev once per step and returns **raw probabilities**.
///
/// ```
///   JevClient                        call site (Loop / Safety)
///   ─────────                        ────────────────────────
///   returns raw Double        ──►    applies Constants.Jev.selectionConfidence
///   probabilities, verbatim          applies Constants.Jev.selectionMargin
///   NEVER thresholds                 decides
/// ```
///
/// **This type never thresholds and never decides.** It reads
/// `Constants.Jev.requestTimeout` and the retry knobs, because those are
/// transport policy; anything that turns a probability into a verdict lives at
/// the call site. That separation is what keeps `Constants.swift` reviewable as
/// the one file a human reads to understand behaviour — SPEC.md § Code Style.
public actor JevClient: StepJudge {
  private let apiKey: String
  private let model: String
  private let transport: any JevTransport
  private let policy: RetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let random: @Sendable () -> Double
  private let baseURL: URL

  public init(
    apiKey: String,
    model: String = Constants.Models.jev,
    baseURL: URL = Constants.Jev.baseURL,
    transport: any JevTransport = URLSessionTransport(),
    policy: RetryPolicy = RetryPolicy(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.apiKey = apiKey
    self.model = model
    self.baseURL = baseURL
    self.transport = transport
    self.policy = policy
    self.sleep = sleep
    self.random = random
  }

  /// Convenience: resolves `TYPESAFE_API_KEY` from the environment.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any JevTransport = URLSessionTransport()
  ) throws {
    self.init(apiKey: try Credentials.apiKey(environment: environment), transport: transport)
  }

  // MARK: - The step battery

  /// Opens the HTTP connection ahead of the first step. Fire and forget; see
  /// `URLSessionTransport.warm(_:)` for what this is worth and why it is safe.
  public func warm() async {
    await transport.warm(baseURL)
  }

  /// One batched request carrying verification, selection and intent risk.
  ///
  /// - Parameter budgetRemaining: what is left of this step's deadline. Retries
  ///   are clamped by it, so the call cannot outlive the step that issued it.
  public func step(
    _ context: StepContext,
    budgetRemaining: Duration = Constants.Budget.stepTimeout
  ) async throws -> StepVerdict {
    let questions = Batteries.step(
      candidates: context.candidates,
      includeWrongContext: context.namesAnInstance
    )
    let (response, requestID) = try await evaluate(
      state: context, questions: questions, budgetRemaining: budgetRemaining
    )

    // An alias moving is a silent behavioural change, and every threshold in
    // this project was tuned against one version. Logged, not thrown: killing
    // a task mid-run over a vendor-side alias change would be worse than
    // finishing it with a recorded discrepancy.
    if response.model != model {
      Log.warn("jev model mismatch: requested \(model), answered \(response.model)")
    }

    func noul(_ id: String) throws -> Double {
      guard let answer = response.answers[id] else {
        throw JevError.malformedResponse(field: "answers.\(id) missing")
      }
      guard let value = answer.noulValue else {
        throw JevError.malformedResponse(field: "answers.\(id) is not a noul")
      }
      return value
    }

    return StepVerdict(
      progressed: try noul(Batteries.ID.progressed),
      unchanged: try noul(Batteries.ID.unchanged),
      blocked: try noul(Batteries.ID.blocked),
      taskDone: try noul(Batteries.ID.taskDone),
      looping: try noul(Batteries.ID.looping),
      // Absent by design when the task named no instance.
      wrongContext: response.answers[Batteries.ID.wrongContext]?.noulValue,
      // Absent when perception produced no candidates. The verification
      // half of the batch is still meaningful, and the loop needs it to
      // tell "blocked" from "done" from "merely empty".
      target: response.answers[Batteries.ID.target]?.choiceValue,
      sufficient: try noul(Batteries.ID.sufficient),
      riskDestructive: try noul(Batteries.ID.riskDestructive),
      riskOutbound: try noul(Batteries.ID.riskOutbound),
      riskCredential: try noul(Batteries.ID.riskCredential),
      modelVersion: response.model,
      usage: response.usage,
      requestID: requestID
    )
  }

  // MARK: - Transport

  /// Sends one batch, retrying within the step deadline.
  func evaluate(
    state: StepContext,
    questions: [String: Question],
    budgetRemaining: Duration
  ) async throws -> (JevResponse, String?) {

    try preflight(state: state, questions: questions)

    let body = try JSONEncoder().encode(
      JevRequest(state: state, model: model, questions: questions)
    )
    var request = URLRequest(url: baseURL.appending(path: "v1/systemone"))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var remaining = budgetRemaining
    var attempt = 0

    while true {
      let started = ContinuousClock.now
      do {
        let (data, http) = try await transport.send(request, timeout: Constants.Jev.requestTimeout)
        // The only handle for vendor support. Logged on every path,
        // success and failure alike.
        let requestID = http.value(forHTTPHeaderField: "x-typesafe-request-id")

        if let error = JevError.from(
          status: http.statusCode,
          detail: Self.detail(from: data),
          retryAfter: Self.retryAfter(from: http)
        ) {
          throw error
        }

        let decoded: JevResponse
        do {
          decoded = try JSONDecoder().decode(JevResponse.self, from: data)
        } catch let error as JevError {
          throw error
        } catch {
          throw JevError.malformedResponse(field: "\(error)")
        }
        Log.debug("jev ok request-id=\(requestID ?? "-") tokens=\(decoded.usage.inputTokens)")
        return (decoded, requestID)

      } catch let error as JevError {
        remaining -= ContinuousClock.now - started

        let retryAfter: Duration? = if case .rateLimited(let after) = error { after } else { nil }
        let delay = policy.delay(
          afterAttempt: attempt, retryAfter: retryAfter, randomUnit: random())

        guard
          policy.shouldRetry(
            error: error, attempt: attempt, delay: delay, remaining: remaining
          )
        else {
          Log.warn("jev failed: \(error) (attempt \(attempt + 1), \(remaining.inSeconds)s left)")
          throw error
        }

        Log.info(
          "jev retry \(attempt + 1)/\(policy.maxRetries) after \(delay.inSeconds)s: \(error)")
        try await sleep(delay)
        remaining -= delay
        attempt += 1
      }
    }
  }

  // MARK: - Preflight

  /// Refuses requests the API will certainly reject, so the failure names its
  /// own cause here rather than arriving as an opaque `400` or `422`.
  func preflight(state: StepContext, questions: [String: Question]) throws {
    if case .choice(_, let criteria)? = questions[Batteries.ID.target],
      criteria.count > Constants.Jev.maxCandidates
    {
      throw JevError.tooManyCandidates(
        count: criteria.count, limit: Constants.Jev.maxCandidates
      )
    }

    let estimate = Self.estimateTokens(state)
    if estimate > Constants.Jev.stateTokenLimit {
      throw JevError.stateTooLarge(
        estimatedTokens: estimate, limit: Constants.Jev.stateTokenLimit
      )
    }
  }

  /// Rough token count for the preflight. See
  /// `Constants.Jev.charactersPerTokenEstimate` — a heuristic, not a
  /// measurement, and deliberately conservative.
  static func estimateTokens(_ state: StepContext) -> Int {
    let encoded = (try? JSONEncoder().encode(state)) ?? Data()
    return encoded.count / Constants.Jev.charactersPerTokenEstimate
  }

  // MARK: - Header and body parsing

  static func detail(from data: Data) -> String {
    (try? JSONDecoder().decode(JevErrorBody.self, from: data))?.detail ?? ""
  }

  /// The vendor's SDKs honour `Retry-After` when the response carries one.
  /// Guessing a shorter delay than the server asked for is how a 429 becomes
  /// a ban.
  static func retryAfter(from response: HTTPURLResponse) -> Duration? {
    guard let raw = response.value(forHTTPHeaderField: "retry-after") else { return nil }
    if let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) {
      return .seconds(seconds)
    }
    return nil
  }
}
