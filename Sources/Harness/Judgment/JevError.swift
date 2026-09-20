import Foundation

/// Every way a Jev call can fail, and whether retrying could possibly help.
///
/// The vendor's own HTTP error table documents only 401, 422, 429 and 529, but
/// its Python SDK exception hierarchy additionally raises on 400, 403, 404, 408
/// and 5xx. The SDK is the more complete contract, so this enum follows it.
public enum JevError: Error, Equatable, Sendable {
  /// 401. Missing or invalid API key. **Never retried** — a second request
  /// with the same key produces the same answer.
  case unauthorized
  /// 400. Malformed request. Ours to fix: too many choices, too many score
  /// levels, a bad primitive.
  case badRequest(detail: String)
  /// 403.
  case forbidden
  /// 404.
  case notFound
  /// 408, and `URLError.timedOut`.
  case timedOut
  /// 422. Unprocessable. Ours to fix.
  case unprocessable(detail: String)
  /// 429. Over 250,000 tok/s or 1,200 req/min. `retryAfter` is the parsed
  /// header when the response carried one.
  case rateLimited(retryAfter: Duration?)
  /// 529. Vendor overloaded.
  case overloaded
  /// Any other 5xx.
  case server(status: Int)
  /// Transport failure below HTTP.
  case transport(code: Int)
  /// The response did not match the documented schema. **Never retried** —
  /// a schema mismatch is deterministic.
  case malformedResponse(field: String)
  /// `TYPESAFE_API_KEY` is not set, or is empty.
  case missingAPIKey(variable: String)
  /// A request was built that the API will certainly reject. Caught locally so
  /// the failure names its own cause instead of arriving as an opaque 400.
  case tooManyCandidates(count: Int, limit: Int)
  /// The `state` is too large for the documented 32k budget.
  case stateTooLarge(estimatedTokens: Int, limit: Int)

  /// Whether another attempt could plausibly succeed.
  ///
  /// Mirrors the vendor SDK's `http_statuses={408, 429, *range(500,600)}`,
  /// plus 529. Everything else is either our bug or a credential problem, and
  /// retrying it burns the step deadline to reach the same answer.
  public var isRetryable: Bool {
    switch self {
    case .timedOut, .rateLimited, .overloaded, .server, .transport:
      true
    case .unauthorized, .badRequest, .forbidden, .notFound, .unprocessable,
      .malformedResponse, .missingAPIKey, .tooManyCandidates, .stateTooLarge:
      false
    }
  }

  /// Maps an HTTP status to the error it represents.
  ///
  /// - Parameter retryAfter: the parsed `Retry-After` header, when present.
  ///   The vendor SDKs honour it and a hand-rolled client must too.
  public static func from(status: Int, detail: String = "", retryAfter: Duration? = nil)
    -> JevError?
  {
    switch status {
    case 200..<300: nil
    case 400: .badRequest(detail: detail)
    case 401: .unauthorized
    case 403: .forbidden
    case 404: .notFound
    case 408: .timedOut
    case 422: .unprocessable(detail: detail)
    case 429: .rateLimited(retryAfter: retryAfter)
    case 529: .overloaded
    case 500..<600: .server(status: status)
    default: .server(status: status)
    }
  }
}
