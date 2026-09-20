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
/// Two sources, in this order:
///
///   1. the environment — `direnv`, an `export`, a CI secret;
///   2. `~/.config/open-agent/credentials`, holding the key and nothing else.
///
/// The environment wins because an explicit `export` is the thing a person
/// reaches for when they want to override what is installed, and a stored file
/// that silently outranked it would make that impossible.
///
/// **The file exists because the binary is installed globally and the
/// environment is not.** ADR 0012: `install.sh` puts `open-agent` in
/// `~/.local/bin`, the skill invokes it by name from whatever directory the host
/// coding agent happens to be in, and `direnv` only exports inside the checkout.
/// A credential scoped to one directory cannot authenticate a command that runs
/// everywhere.
///
/// **This is still not a `.env` parser**, and the distinction is the whole
/// reason the file has its own name and format. `.env` is a format — `export `
/// prefixes, `#` inside quoted values, CRLF, escapes, the parts people get wrong
/// in fifteen lines. This file is one secret, read whole and trimmed. There is
/// nothing to get wrong because there is nothing to parse.
///
/// Known future break: a Finder-launched `.app` inherits neither the shell
/// environment nor, necessarily, a readable home. Nothing bundles an `.app`
/// today. When one ships, the third source is Keychain, and the shape below is
/// `env → file → Keychain` so that is one more case. Never `UserDefaults`,
/// which is a world-readable plist in `~/Library/Preferences`.
public enum Credentials {

  /// The environment variable the vendor's SDKs read.
  public static let apiKeyVariable = "TYPESAFE_API_KEY"

  /// Where the installed binary looks when the environment is silent.
  ///
  /// Under `~/.config` rather than `~/Library/Application Support` because the
  /// thing that writes it is a POSIX shell script and the thing that reads it is
  /// a command-line tool; both conventions are defensible and only one of them
  /// can be typed from memory.
  public static var credentialsFile: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/open-agent/credentials")
      .path
  }

  /// Resolves the API key, or throws naming the variable that is missing.
  ///
  /// **Never `?? ""`.** An empty key produces a 401 that then has to be
  /// diagnosed against the vendor's error table, instead of a message that
  /// says what to export. An empty or whitespace-only value is treated as
  /// absent — in the environment it falls through to the file, and in the file
  /// it fails — for exactly that reason.
  ///
  /// - Parameter file: the fallback path. `nil` disables the fallback, which is
  ///   what the unit tests use to assert the environment path in isolation.
  public static func apiKey(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    file: String? = credentialsFile
  ) throws -> String {
    if let fromEnvironment = nonEmpty(environment[apiKeyVariable]) {
      return fromEnvironment
    }
    if let file, let fromFile = nonEmpty(readCredentialsFile(at: file)) {
      return fromFile
    }
    throw JevError.missingAPIKey(variable: apiKeyVariable)
  }

  private static func nonEmpty(_ raw: String?) -> String? {
    guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else { return nil }
    return key
  }

  /// Reads the credentials file, tightening its mode first if it is readable by
  /// anyone but its owner.
  ///
  /// Tighten rather than refuse. `ssh` refuses a loose private key and it is
  /// right to, because a key that leaked has to be replaced and the user needs
  /// to know. A missing API key is not that: refusing would abort the task at
  /// the moment it matters, and the only thing the user could do in response is
  /// run this exact `chmod`. So run it, and leave the key working.
  private static func readCredentialsFile(at path: String) -> String? {
    let manager = FileManager.default
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    if let mode = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber,
      mode.intValue & 0o077 != 0
    {
      try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    return contents
  }

  /// Human-readable guidance for a missing key. Printed to stderr, never stdout —
  /// stdout carries exactly one JSON object per invocation.
  public static var missingKeyGuidance: String {
    """
    \(apiKeyVariable) is not set, and \(credentialsFile) does not hold a key.

    The installed command runs from any directory, so give it a credential that
    does too:
        mkdir -p ~/.config/open-agent
        printf %s "$\(apiKeyVariable)" > \(credentialsFile)
        chmod 600 \(credentialsFile)

    Or export it for this shell only:
        export \(apiKeyVariable)=...
    In the checkout, .env plus `direnv allow` does that for you.

    Note the name: TYPESAFE_API_KEY. TypeSafe is the vendor; Jev is the model.
    Keys are issued at https://console.typesafe.ai/keys
    """
  }
}
