import Foundation
import Testing

@testable import Harness

/// Which profile the agent drives — ADR 0011.
///
/// Getting this wrong opens the wrong browser, which is what the first version
/// did: it launched an empty dedicated profile beside the one the user was
/// actually working in.
@Suite("Browser profile resolution")
struct BrowserProfileTests {

  static func withINI(_ contents: String, _ body: (String) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "oa-profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try contents.write(
      to: root.appending(path: "profiles.ini"), atomically: true, encoding: .utf8
    )
    try body(root.path)
  }

  /// **The per-install `Default=` wins.**
  ///
  /// This is the real `profiles.ini` shape from the machine this was built
  /// against, and the two keys disagree: `[Install…] Default=` points at
  /// `Default (release)` while `[Profile1] Default=1` points at
  /// `Default Profile`. The browser honours the install key. Reading the other
  /// one opens a profile the user has never seen.
  @Test("the per-install default wins over a Default=1 profile flag")
  func installDefaultWins() throws {
    try Self.withINI(
      """
      [Install6ED35B3CA1B5D3AF]
      Default=Profiles/9ho70bff.Default (release)
      Locked=1

      [Profile1]
      Name=Default Profile
      IsRelative=1
      Path=Profiles/lgw7qq8e.Default Profile
      Default=1

      [Profile0]
      Name=Default (release)
      IsRelative=1
      Path=Profiles/9ho70bff.Default (release)

      [General]
      StartWithLastProfile=1
      Version=2
      """
    ) { root in
      let resolved = BrowserProfile.resolveDefault(root: root)
      #expect(resolved?.hasSuffix("Profiles/9ho70bff.Default (release)") == true)
      #expect(resolved?.contains("lgw7qq8e") == false, "must not pick the Default=1 profile")
    }
  }

  /// A profile path containing spaces is normal on macOS and must survive.
  @Test("a path with spaces resolves intact")
  func pathWithSpaces() throws {
    try Self.withINI(
      """
      [Install1]
      Default=Profiles/abc.Default (release)
      """
    ) { root in
      #expect(BrowserProfile.resolveDefault(root: root)?.hasSuffix("Default (release)") == true)
    }
  }

  @Test("falls back to Default=1 when no install section exists")
  func fallsBackToProfileFlag() throws {
    try Self.withINI(
      """
      [Profile0]
      Path=Profiles/aaa.one

      [Profile1]
      Path=Profiles/bbb.two
      Default=1
      """
    ) { root in
      #expect(BrowserProfile.resolveDefault(root: root)?.hasSuffix("Profiles/bbb.two") == true)
    }
  }

  @Test("falls back to the first profile when nothing is flagged")
  func fallsBackToFirst() throws {
    try Self.withINI(
      """
      [Profile0]
      Path=Profiles/aaa.one

      [Profile1]
      Path=Profiles/bbb.two
      """
    ) { root in
      #expect(BrowserProfile.resolveDefault(root: root)?.hasSuffix("Profiles/aaa.one") == true)
    }
  }

  /// An absolute `Path=` is left alone rather than joined onto the root.
  @Test("an absolute path is not re-rooted")
  func absolutePath() throws {
    try Self.withINI(
      """
      [Install1]
      Default=/Volumes/External/zen/custom
      """
    ) { root in
      #expect(BrowserProfile.resolveDefault(root: root) == "/Volumes/External/zen/custom")
    }
  }

  @Test("a missing profiles.ini resolves to nil rather than guessing")
  func missingINI() {
    #expect(BrowserProfile.resolveDefault(root: "/nonexistent/path") == nil)
  }

  /// When resolution fails, the dedicated profile is the safe landing place —
  /// an empty profile does nothing, which is better than opening one at random.
  @Test("an explicit override always wins")
  func overrideWins() {
    #expect(BrowserProfile.active(override: "/tmp/somewhere") == "/tmp/somewhere")
  }
}
