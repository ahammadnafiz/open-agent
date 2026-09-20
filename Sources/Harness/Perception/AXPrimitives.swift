import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, total wrappers over the C accessibility API.
///
/// Every one of these returns an optional rather than throwing. An absent
/// attribute is the normal case in AX — most elements do not implement most
/// attributes — so an error type here would be noise at every call site.
enum AXPrimitives {

  static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
  }

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    copyValue(element, attribute) as? String
  }

  static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    copyValue(element, attribute) as? Bool
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    copyValue(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
  }

  static func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
  }

  /// Screen frame in Quartz coordinates (origin top-left).
  ///
  /// Read from `kAXFrameAttribute` when the element offers it, falling back to
  /// position + size. Both are `AXValue` boxes and neither is a plain CGRect.
  static func frame(_ element: AXUIElement) -> CGRect? {
    if let raw = copyValue(element, "AXFrame") {
      var rect = CGRect.zero
      // swift-format-ignore: NeverForceUnwrap
      if AXValueGetValue(raw as! AXValue, .cgRect, &rect) { return rect }
    }
    guard let rawPoint = copyValue(element, kAXPositionAttribute as String),
      let rawSize = copyValue(element, kAXSizeAttribute as String)
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    // swift-format-ignore: NeverForceUnwrap
    guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &origin),
      // swift-format-ignore: NeverForceUnwrap
      AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  /// The label, in the precedence the accessibility API actually rewards.
  ///
  /// Title first because it is what a human reads, then description for
  /// icon-only controls that carry `AXDescription`, then value for text fields
  /// whose content *is* their identity in a file list.
  static func label(_ element: AXUIElement) -> String {
    let candidates = [
      string(element, kAXTitleAttribute as String),
      string(element, kAXDescriptionAttribute as String),
      // Placeholder before value, and that order is deliberate.
      //
      // **An empty text field has no label at all**, and the candidate filter
      // keeps only elements that have one — so the moment you click into a
      // search box it drops out of the element list, which is exactly when the
      // next step needs to name it. Measured on WhatsApp: the field reads
      // `Search` until it is focused, then reads nothing, and the `type` step
      // after the `click` step reported "the target is not in the element
      // list" at 0.69 against a 0.70 floor.
      //
      // Placeholder also outranks value because it is what the field *is*
      // rather than what is currently in it. A search box does not stop being
      // the search box once someone types in it, and a label that changes
      // under the agent's own keystrokes makes the same element look like a
      // different one between two consecutive steps.
      string(element, kAXPlaceholderValueAttribute as String),
      string(element, kAXValueAttribute as String),
    ]
    for candidate in candidates {
      let trimmed = cleaned(candidate ?? "")
      if !trimmed.isEmpty { return trimmed }
    }
    return ""
  }

  /// Strips the characters that are in a label but not in its meaning.
  ///
  /// **Applications really do put invisible characters in their labels.**
  /// Measured on WhatsApp: every label arrives with a leading `U+200E`
  /// LEFT-TO-RIGHT MARK — `‎Search`, `‎Compose message` — which its own
  /// bundle strings do not have. Nothing shows it: not a screenshot, not a log
  /// line, not a diff.
  ///
  /// Two things break on it. Jev reads these labels to decide which candidate a
  /// plan step is naming, and a step saying "the Search field" against a
  /// candidate that is not quite `Search` is a worse match than it should be.
  /// And `LabelDenylist` matches on this string — a format character sitting
  /// inside a word would carry a denylisted term straight past the check, which
  /// is the one place a silent mismatch is dangerous rather than annoying.
  ///
  /// Format characters (Unicode general category Cf) carry no identity; they
  /// tell a text renderer what to do. The same reasoning as
  /// `WindowGuard.normalized(appName:)`, at the layer where it matters more.
  static func cleaned(_ label: String) -> String {
    String(label.unicodeScalars.filter { $0.properties.generalCategory != .format })
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether this process may inspect other applications' UI.
  ///
  /// **The grant is per-binary.** A freshly compiled executable is untrusted
  /// even when run from a granted terminal, so `Probe` and the shipped binary
  /// each need their own grant. Listing processes needs no permission, which
  /// makes it look like AX works right up until the first attribute read
  /// returns `-25211 (APIDisabled)`.
  static func isTrusted(prompt: Bool = false) -> Bool {
    // The literal key rather than `kAXTrustedCheckOptionPrompt`: that global
    // is declared `var` in the SDK, which Swift 6 strict concurrency rejects
    // as shared mutable state. The string is the documented, stable value.
    let options = ["AXTrustedCheckOptionPrompt": prompt]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  }
}
