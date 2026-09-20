import Foundation

extension Duration {
  /// Seconds as a `Double`. Backoff arithmetic is fractional and `Duration`
  /// only multiplies by integers.
  public var inSeconds: Double {
    let c = components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }
}

/// Exponential backoff, **clamped by the step deadline**.
///
/// The clamp is the whole point. Unclamped, the vendor's own defaults overrun
/// this project's step budget:
///
/// ```
///   10s request + 0.5s + 10s + 1.0s + 10s  =  31.5s
///   Constants.Budget.stepTimeout           =  20.0s
///                                             ^^^^^^ over by 57%
/// ```
///
/// A step that exhausts its retries unclamped is killed mid-retry by the step
/// timeout, and the log records a timeout rather than the rate limit that
/// actually caused it. The operator then debugs the wrong thing.
///
/// Pure and deterministic: randomness and the clock are both injected, so every
/// branch is unit-testable offline.
public struct RetryPolicy: Sendable, Equatable {
  public let maxRetries: Int
  public let initialBackoff: Duration
  public let maxBackoff: Duration
  public let jitterFraction: Double

  public init(
    maxRetries: Int = Constants.Jev.maxRetries,
    initialBackoff: Duration = Constants.Jev.backoffInitial,
    maxBackoff: Duration = Constants.Jev.backoffMax,
    jitterFraction: Double = Constants.Jev.backoffJitter
  ) {
    self.maxRetries = maxRetries
    self.initialBackoff = initialBackoff
    self.maxBackoff = maxBackoff
    self.jitterFraction = jitterFraction
  }

  /// Backoff before the attempt that follows `attempt` (0-indexed), ignoring
  /// jitter and `Retry-After`. Doubles each time, capped at `maxBackoff`.
  public func baseBackoff(afterAttempt attempt: Int) -> Duration {
    let factor = pow(2.0, Double(max(0, attempt)))
    let seconds = min(initialBackoff.inSeconds * factor, maxBackoff.inSeconds)
    return .seconds(seconds)
  }

  /// The delay actually waited before the next attempt.
  ///
  /// `Retry-After` wins outright when the server sent one — the vendor
  /// documents that its SDKs honour the header, and guessing a shorter delay
  /// than the server asked for is how a 429 becomes a ban.
  ///
  /// - Parameter randomUnit: a value in `0...1`. Injected rather than drawn so
  ///   the jitter band is assertable. The vendor publishes `backoff_jitter=0.25`
  ///   but not the formula; this applies it as a symmetric ±25% band, which is
  ///   the common reading. Documented because it is an assumption, not a fact.
  public func delay(afterAttempt attempt: Int, retryAfter: Duration?, randomUnit: Double)
    -> Duration
  {
    if let retryAfter { return retryAfter }
    let base = baseBackoff(afterAttempt: attempt).inSeconds
    let clamped = min(max(randomUnit, 0), 1)
    let scale = (1.0 - jitterFraction) + (2.0 * jitterFraction * clamped)
    return .seconds(base * scale)
  }

  /// Whether to make another attempt.
  ///
  /// Three conditions, all required:
  ///   1. the error is one another attempt could fix,
  ///   2. the retry allowance is not spent,
  ///   3. **the delay plus a full request timeout still fits in what is left
  ///      of the step deadline** — no attempt is started that cannot finish.
  public func shouldRetry(
    error: JevError,
    attempt: Int,
    delay: Duration,
    remaining: Duration,
    requestTimeout: Duration = Constants.Jev.requestTimeout
  ) -> Bool {
    guard error.isRetryable else { return false }
    guard attempt < maxRetries else { return false }
    return delay + requestTimeout <= remaining
  }
}
