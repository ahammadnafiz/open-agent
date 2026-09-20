import Foundation
import Testing

@testable import Harness

@Suite("LabelDenylist")
struct LabelDenylistTests {

  /// The pattern is force-compiled at first use. If it does not compile, every
  /// classification silently stops matching and the confirmation boundary
  /// disappears. This is the test that makes the force-unwrap defensible.
  @Test("the denylist pattern compiles")
  func patternCompiles() throws {
    _ = try NSRegularExpression(
      pattern: Constants.Safety.labelDenylist,
      options: [.allowCommentsAndWhitespace, .caseInsensitive]
    )
  }

  /// `Constants.Safety.irreversibleKinds` exists so the list is visible in the
  /// file humans review. The enum is the source of truth. This asserts they
  /// never drift.
  @Test("irreversibleKinds mirrors ActionKind.isIrreversibleByDefault")
  func constantMirrorsEnum() {
    let fromEnum = Set(ActionKind.allCases.filter(\.isIrreversibleByDefault).map(\.rawValue))
    #expect(fromEnum == Constants.Safety.irreversibleKinds)
  }

  @Test("case insensitive", arguments: ["POST", "post", "Post", "pOsT"])
  func caseInsensitive(label: String) {
    #expect(LabelDenylist.matches(label))
  }

  /// Word-bounded, so a denylist term embedded in a larger word does not fire.
  /// "Repayment" contains "pay"; "Sender" contains "send".
  @Test(
    "matches on word boundaries only",
    arguments: [
      "Repayment", "Senders", "Postal code", "Deleted items count", "Ordering",
    ])
  func wordBoundaries(label: String) {
    #expect(!LabelDenylist.matches(label), "'\(label)' must not match")
  }

  /// The boundary is a real word boundary, so the term still fires inside a
  /// phrase. This is the direction that matters: "Send message" must confirm.
  @Test(
    "matches a term inside a phrase",
    arguments: [
      "Send message", "Delete this file", "Confirm and pay", "Post to feed",
    ])
  func insidePhrase(label: String) {
    #expect(LabelDenylist.matches(label))
  }

  /// An absent label is not evidence of safety — it is absence of evidence.
  /// Conflating the two here would make every unlabelled element irreversible,
  /// which measured as unusable: Chrome is 83% icon-only. The
  /// unnamed-**captured** rule is what covers the genuinely nameless case.
  @Test("nil, empty and whitespace do not match")
  func emptyDoesNotMatch() {
    #expect(!LabelDenylist.matches(nil))
    #expect(!LabelDenylist.matches(""))
    #expect(!LabelDenylist.matches("   \n\t "))
  }

  @Test(
    "ordinary labels do not match",
    arguments: [
      "Preferences", "New mail", "Archive", "Home", "Back", "Cancel", "Settings",
    ])
  func ordinaryLabels(label: String) {
    #expect(!LabelDenylist.matches(label))
  }

  @Test("submit roles match regardless of label")
  func submitRoles() {
    for role in Constants.Safety.submitRoles {
      #expect(LabelDenylist.matchesRole(role))
      #expect(LabelDenylist.matchesRole(role.uppercased()))
    }
    #expect(!LabelDenylist.matchesRole("AXButton"))
    #expect(!LabelDenylist.matchesRole(nil))
  }

  /// Known gap, asserted so it is visible rather than discovered. A non-English
  /// UI falls back to the planner's declared intent alone, which is the weaker
  /// half of the classification.
  @Test("non-English labels do not match — a documented gap")
  func nonEnglishIsAKnownGap() {
    #expect(!LabelDenylist.matches("Envoyer"))
    #expect(!LabelDenylist.matches("削除"))
  }
}
