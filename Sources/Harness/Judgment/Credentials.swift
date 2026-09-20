import Foundation

/// How the binary gets its TypeSafe API key.
///
/// **`TYPESAFE_API_KEY`, not `JEV_API_KEY`.** Jev is the *model*
/// (`jev-1.13.0`); TypeSafe is the *vendor* whose API is authenticated against.
/// The name matches the vendor's own SDK convention, so a `.env` written for the
/// Python or JS SDK works here unchanged — which matters because
/// `Probe battery-eval` will want to cross-check against a reference
/// implementation.
///
/// There is no Swift SDK, so nothing reads this variable for us.
///
/// **No `.env` parser lives in this codebase.** Swift cannot read `.env` files
/// natively, and a hand-rolled parser is fifteen lines of the parts people get
/// wrong: `export ` prefixes, `#` inside quoted values, CRLF, escapes. The file
/// is bridged into the environment outside Swift — `direnv`, or
/// `set -a; source .env; set +a` in a wrapper. Every documented invocation of
/// this project is `swift run` from a terminal, which inherits the shell
/// environment for free.
///
/// Known future break: a Finder-launched `.app` does **not** inherit the shell
/// environment, because `launchd` never sourced a shell profile. Nothing bundles
/// an `.app` today. When one ships, the second source is Keychain, and the shape
/// below is `env → Keychain` so that is a one-line change. Never `UserDefaults`,
/// which is a world-readable plist in `~/Library/Preferences`.
public enum Credentials {

  /// The environment variable the vendor's SDKs read.
  public static let apiKeyVariable = "TYPESAFE_API_KEY"

  /// Resolves the API key, or throws naming the variable that is missing.
  ///
  /// **Never `?? ""`.** An empty key produces a 401 that then has to be
  /// diagnosed against the vendor's error table, instead of a message that
  /// says what to export. An empty or whitespace-only value is treated as
  /// absent for exactly that reason.
  public static func apiKey(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    guard let raw = environment[apiKeyVariable] else {
      throw JevError.missingAPIKey(variable: apiKeyVariable)
    }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw JevError.missingAPIKey(variable: apiKeyVariable)
    }
    return key
  }

  /// Human-readable guidance for a missing key. Printed to stderr, never stdout —
  /// stdout carries exactly one JSON object per invocation.
  public static var missingKeyGuidance: String {
    """
    \(apiKeyVariable) is not set.

    Export it, or put it in .env and use direnv:
        echo 'dotenv' > .envrc && direnv allow
    Or source it for one command:
        set -a; source .env; set +a

    Note the name: TYPESAFE_API_KEY. TypeSafe is the vendor; Jev is the model.
    Keys are issued at https://console.typesafe.ai/keys
    """
  }
}
