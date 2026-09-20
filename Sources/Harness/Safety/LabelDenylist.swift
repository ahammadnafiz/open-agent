import Foundation

/// A compiled regex over an element's label, plus a role check.
///
/// This exists because **the verb never tells you what a click does.**
/// Publishing a tweet is `click("Post")`, and `click` is reversible. Without
/// this rule the entire confirmation boundary is bypassed by the ordinary
/// mechanics of the task.
///
/// **Upgrade-only.** Matching forces `.irreversible`, never the reverse. False
/// positives are accepted: a search form whose button says "Submit" asks once,
/// which is the correct direction to be wrong in.
///
/// English-only, and that is a known gap — a non-English UI falls back to the
/// planner's declared intent alone, which is the weaker half.
public enum LabelDenylist {

  /// Compiled once. A regex recompiled per call would be the single hottest
  /// allocation in the safety path, and this path runs on every action.
  ///
  /// Force-unwrapped deliberately: the pattern is a compile-time constant in
  /// `Constants.Safety.labelDenylist`. If it does not compile, every
  /// classification silently stops matching and the confirmation boundary
  /// disappears — a crash at startup is enormously preferable, and
  /// `SafetyTests` asserts the pattern compiles.
  private static let regex: NSRegularExpression = {
    // swift-format-ignore: NeverForceUnwrap
    try! NSRegularExpression(
      pattern: Constants.Safety.labelDenylist,
      options: [.allowCommentsAndWhitespace, .caseInsensitive]
    )
  }()

  /// Whether a label names something that cannot be undone.
  ///
  /// `nil` and empty both return `false`. An absent label is not evidence of
  /// safety — it is absence of evidence — and the unnamed-captured rule in
  /// `Irreversibility.classify` is what covers that case. Conflating the two
  /// here would make every unlabelled element irreversible, which measured as
  /// unusable: Chrome is 83% icon-only.
  public static func matches(_ label: String?) -> Bool {
    guard let label else { return false }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    return regex.firstMatch(in: trimmed, options: [], range: range) != nil
  }

  /// Roles that imply form submission regardless of label.
  public static func matchesRole(_ role: String?) -> Bool {
    guard let role else { return false }
    return Constants.Safety.submitRoles.contains(role.lowercased())
  }
}
