import Foundation
import Testing

@testable import Harness

@Suite("RetryPolicy")
struct RetryPolicyTests {
  let policy = RetryPolicy()

  @Test("backoff doubles from the vendor default")
  func backoffDoubles() {
    #expect(policy.baseBackoff(afterAttempt: 0).inSeconds == 0.5)
    #expect(policy.baseBackoff(afterAttempt: 1).inSeconds == 1.0)
    #expect(policy.baseBackoff(afterAttempt: 2).inSeconds == 2.0)
  }

  @Test("backoff is capped at maxBackoff")
  func backoffCapped() {
    #expect(policy.baseBackoff(afterAttempt: 20).inSeconds == Constants.Jev.backoffMax.inSeconds)
  }

  /// Jitter is applied as a symmetric band. The midpoint must be the
  /// unjittered value, or the effective backoff silently drifts.
  @Test("jitter stays inside its band and is centred")
  func jitterBand() {
    let base = policy.baseBackoff(afterAttempt: 0).inSeconds
    let low = policy.delay(afterAttempt: 0, retryAfter: nil, randomUnit: 0).inSeconds
    let mid = policy.delay(afterAttempt: 0, retryAfter: nil, randomUnit: 0.5).inSeconds
    let high = policy.delay(afterAttempt: 0, retryAfter: nil, randomUnit: 1).inSeconds

    #expect(abs(low - base * (1 - policy.jitterFraction)) < 1e-9)
    #expect(abs(mid - base) < 1e-9)
    #expect(abs(high - base * (1 + policy.jitterFraction)) < 1e-9)
  }

  @Test("randomUnit outside 0...1 is clamped, not extrapolated")
  func randomUnitClamped() {
    let base = policy.baseBackoff(afterAttempt: 0).inSeconds
    #expect(
      policy.delay(afterAttempt: 0, retryAfter: nil, randomUnit: -5).inSeconds
        == base * (1 - policy.jitterFraction))
    #expect(
      policy.delay(afterAttempt: 0, retryAfter: nil, randomUnit: 5).inSeconds
        == base * (1 + policy.jitterFraction))
  }

  @Test("Retry-After overrides computed backoff entirely")
  func retryAfterWins() {
    let d = policy.delay(afterAttempt: 0, retryAfter: .seconds(7), randomUnit: 0.5)
    #expect(d == .seconds(7))
  }

  @Test(
    "non-retryable errors never retry",
    arguments: [
      JevError.unauthorized, .forbidden, .notFound,
      .badRequest(detail: ""), .unprocessable(detail: ""),
      .malformedResponse(field: "x"), .missingAPIKey(variable: "X"),
    ])
  func nonRetryable(error: JevError) {
    #expect(!error.isRetryable)
    #expect(
      !policy.shouldRetry(
        error: error, attempt: 0, delay: .zero, remaining: .seconds(600)
      ))
  }

  @Test(
    "retryable errors retry while budget allows",
    arguments: [
      JevError.timedOut, .rateLimited(retryAfter: nil), .overloaded,
      .server(status: 503), .transport(code: -1005),
    ])
  func retryable(error: JevError) {
    #expect(error.isRetryable)
    #expect(
      policy.shouldRetry(
        error: error, attempt: 0, delay: .milliseconds(500), remaining: .seconds(600)
      ))
  }

  /// **The finding this policy exists for.**
  ///
  ///   10s request + 0.5s + 10s + 1.0s + 10s = 31.5s  against a 20s step budget.
  ///
  /// An attempt that cannot finish inside the deadline is never started, so the
  /// step surfaces the real cause instead of a misleading timeout.
  @Test("an attempt that cannot finish inside the deadline is not started")
  func deadlineClamp() {
    let error = JevError.rateLimited(retryAfter: nil)
    let delay = Duration.milliseconds(500)

    // Plenty of room.
    #expect(policy.shouldRetry(error: error, attempt: 0, delay: delay, remaining: .seconds(20)))
    // Exactly enough: delay + requestTimeout == remaining.
    #expect(
      policy.shouldRetry(
        error: error, attempt: 0, delay: delay,
        remaining: delay + Constants.Jev.requestTimeout
      ))
    // One millisecond short.
    #expect(
      !policy.shouldRetry(
        error: error, attempt: 0, delay: delay,
        remaining: delay + Constants.Jev.requestTimeout - .milliseconds(1)
      ))
  }

  @Test("the retry allowance is spent after maxRetries")
  func allowanceSpent() {
    let error = JevError.overloaded
    #expect(
      policy.shouldRetry(
        error: error, attempt: policy.maxRetries - 1, delay: .zero, remaining: .seconds(600)))
    #expect(
      !policy.shouldRetry(
        error: error, attempt: policy.maxRetries, delay: .zero, remaining: .seconds(600)))
  }

  /// The vendor SDK retry set is `{408, 429, 500..599}`; 529 is documented
  /// separately. This asserts the mapping agrees with both.
  @Test("status mapping matches the documented error contract")
  func statusMapping() {
    #expect(JevError.from(status: 200) == nil)
    #expect(JevError.from(status: 400, detail: "d") == .badRequest(detail: "d"))
    #expect(JevError.from(status: 401) == .unauthorized)
    #expect(JevError.from(status: 403) == .forbidden)
    #expect(JevError.from(status: 404) == .notFound)
    #expect(JevError.from(status: 408) == .timedOut)
    #expect(JevError.from(status: 422, detail: "d") == .unprocessable(detail: "d"))
    #expect(JevError.from(status: 429) == .rateLimited(retryAfter: nil))
    #expect(JevError.from(status: 500) == .server(status: 500))
    #expect(JevError.from(status: 529) == .overloaded)
  }
}

@Suite("Credentials")
struct CredentialsTests {

  /// The vendor's own SDK convention, so a `.env` written for the Python or JS
  /// SDK works here unchanged. **Not `JEV_API_KEY`** — Jev is the model,
  /// TypeSafe is the vendor.
  @Test("the variable is TYPESAFE_API_KEY")
  func variableName() {
    #expect(Credentials.apiKeyVariable == "TYPESAFE_API_KEY")
  }

  @Test("a present key is returned, trimmed")
  func presentKey() throws {
    let key = try Credentials.apiKey(environment: ["TYPESAFE_API_KEY": "  abc123\n"])
    #expect(key == "abc123")
  }

  @Test("an absent key throws naming the variable")
  func absentKey() {
    #expect(throws: JevError.missingAPIKey(variable: "TYPESAFE_API_KEY")) {
      try Credentials.apiKey(environment: [:])
    }
  }

  /// Never `?? ""`. An empty key produces a 401 that then has to be diagnosed
  /// against the vendor's error table, instead of a message saying what to export.
  @Test("an empty or whitespace key is treated as absent", arguments: ["", "   ", "\n\t"])
  func emptyKey(value: String) {
    #expect(throws: JevError.missingAPIKey(variable: "TYPESAFE_API_KEY")) {
      try Credentials.apiKey(environment: ["TYPESAFE_API_KEY": value])
    }
  }

  /// The old name must not work by accident. If it did, a stale `.env` would
  /// half-work and the failure would move somewhere confusing.
  @Test("JEV_API_KEY is not read")
  func legacyNameIgnored() {
    #expect(throws: JevError.missingAPIKey(variable: "TYPESAFE_API_KEY")) {
      try Credentials.apiKey(environment: ["JEV_API_KEY": "abc123"])
    }
  }

  @Test("the guidance names the variable and the console")
  func guidance() {
    #expect(Credentials.missingKeyGuidance.contains("TYPESAFE_API_KEY"))
    #expect(Credentials.missingKeyGuidance.contains("console.typesafe.ai"))
  }
}
