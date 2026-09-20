import Foundation

/// Structured logging to **stderr**.
///
/// stdout carries exactly one JSON object per invocation and nothing else — a
/// host that has to parse prose will eventually parse it wrong. Everything
/// human-facing goes here.
public enum Log {
  public enum Level: String, Sendable { case debug, info, warn, error }

  /// Set once at startup from `--verbose`. Below this, nothing is emitted.
  nonisolated(unsafe) public static var minimumLevel: Level = .info

  private static let order: [Level: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]

  public static func log(_ level: Level, _ message: String) {
    guard (order[level] ?? 0) >= (order[minimumLevel] ?? 1) else { return }
    FileHandle.standardError.write(Data("[\(level.rawValue)] \(message)\n".utf8))
  }

  public static func debug(_ m: String) { log(.debug, m) }
  public static func info(_ m: String) { log(.info, m) }
  public static func warn(_ m: String) { log(.warn, m) }
  public static func error(_ m: String) { log(.error, m) }

  /// Header names whose values must never be written anywhere.
  ///
  /// The vendor SDKs redact secret headers for you at `debug` level. This
  /// client is hand-rolled, so it gets nothing for free — and the vendor's own
  /// docs note that even their SDKs do **not** redact request or response
  /// *bodies*. Redaction here is ours to own, and `JudgmentTests` asserts a
  /// key never reaches a rendered header.
  public static let redactedHeaders: Set<String> = ["authorization", "x-api-key"]

  /// Renders headers with secret values replaced. The only supported way to
  /// put a header set into a log line.
  public static func redacted(_ headers: [String: String]) -> String {
    headers
      .map { key, value in
        redactedHeaders.contains(key.lowercased())
          ? "\(key): <redacted>"
          : "\(key): \(value)"
      }
      .sorted()
      .joined(separator: ", ")
  }
}
