import Foundation
import Testing

@testable import Harness

/// `docs/host-contract.md` §5: *"`SafetyTests` asserts this the way it asserts
/// the rest of ADR 0001 — by enumeration, not by reading the code."*
///
/// The claim being defended is that **no argument, environment variable or
/// config key can approve an irreversible action.** That is not a style
/// preference: page text reaches the host's context by construction, and a
/// measured semantic reframing moved a Jev risk score from 0.98 to 0.42.
/// Anything expressible as an argument is eventually expressible by an injected
/// instruction. A window is not.
///
/// A comment saying so rots. This scans the actual CLI source.
@Suite("No approval flag exists")
struct NoApprovalFlagTests {

  /// Walks up from this file to the package root, so the test does not depend
  /// on the working directory `swift test` happens to be run from.
  static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)  // Tests/SafetyTests/ThisFile.swift
      .deletingLastPathComponent()  // Tests/SafetyTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // package root
  }

  /// Every spelling anyone has ever reached for when they wanted to skip a
  /// confirmation.
  static let forbidden = [
    "--yes", "--force", "--approved", "--approve", "--confirm",
    "--no-confirm", "--skip-confirmation", "--non-interactive", "--assume-yes",
    "OPEN_AGENT_APPROVE", "OPENAGENT_YES", "AUTO_APPROVE",
  ]

  @Test("the CLI parses no flag that could approve an action")
  func cliHasNoApprovalFlag() throws {
    let source = try String(
      contentsOf: Self.packageRoot.appending(path: "Sources/OpenAgent/CLI.swift"),
      encoding: .utf8
    )
    for flag in Self.forbidden {
      // The doc comment naming these as forbidden is allowed to mention
      // them; a `case` that parses one is not.
      #expect(
        !source.contains("case \"\(flag)\""),
        "CLI.swift parses \(flag) — there is no flag that approves an action"
      )
    }
  }

  @Test("the approval-flag set is empty, and stays empty")
  func approvalFlagSetIsEmpty() throws {
    let source = try String(
      contentsOf: Self.packageRoot.appending(path: "Sources/OpenAgent/CLI.swift"),
      encoding: .utf8
    )
    #expect(source.contains("static let approvalFlags: Set<String> = []"))
  }

  /// The skill file is the other place an approval instruction could enter the
  /// system — a host told "pass --yes when you're confident" is a host that
  /// will eventually be told that by a web page.
  @Test("no skill file instructs a host to approve anything")
  func skillFilesDoNotApprove() throws {
    let skills = [
      "skills/claude-code/SKILL.md",
      "skills/codex/SKILL.md",
    ]
    for path in skills {
      let url = Self.packageRoot.appending(path: path)
      let source = try String(contentsOf: url, encoding: .utf8)
      // `docs/host-contract.md` §4: the skill "must not contain any
      // instruction about approving actions". Naming a flag — even to deny it
      // — is the lever an injected instruction reaches for, so the file states
      // the boundary without describing any mechanism.
      for lever in ["--yes", "--force", "--approved", "--approve"] {
        #expect(!source.contains(lever), "\(path) names \(lever)")
      }
      #expect(
        source.lowercased().contains("approval is not part of this interface"),
        "\(path) must state that approval is not the host's to give"
      )
      // Markdown formatting is not semantics: the heading reads
      // "`blocked` is terminal", so backticks come out before matching.
      let lowered = source.lowercased().replacingOccurrences(of: "`", with: "")
      #expect(
        lowered.contains("blocked is terminal") && lowered.contains("do not retry"),
        "\(path) must state that `blocked` is terminal and must not be retried"
      )
    }
  }

  /// `Constants.HUD.confirmationTimeout` must stay `nil`.
  ///
  /// A timeout that defaults to "yes" is a hole in the only unrecoverable
  /// boundary in the system; one that defaults to "no" kills a task while the
  /// user is still reading it.
  @Test("the confirmation sheet never times out")
  func confirmationNeverTimesOut() {
    #expect(Constants.HUD.confirmationTimeout == nil)
  }

  /// `Constants.Safety.confirmUnnamedCaptured` guards the one case with no
  /// other mechanism behind it: a target that neither OCR, the detector, nor
  /// the vision model could name cannot be denylisted at all.
  @Test("an unnameable captured target still confirms")
  func unnamedCapturedStillConfirms() {
    #expect(Constants.Safety.confirmUnnamedCaptured)
  }
}
