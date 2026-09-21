import CoreGraphics
import Foundation

/// Resolves applications and proves their windows are actually on screen.
///
/// Uses `CGWindowListCopyWindowInfo` rather than `NSWorkspace`, so `Harness`
/// stays headless — `Package.swift` declares it "no AppKit, no SwiftUI, no UI of
/// any kind", and that boundary is what lets `Probe` and any future daemon reuse
/// this code.
///
/// **Open Question Q6, and it is a correctness prerequisite, not a nuisance.**
/// A minimized or off-Space window observes as *empty, not as an error*: Zen
/// returned 1 AX node, Finder 2, ghostty 0, while `AXWindows` still reported
/// handles. The agent would read that as "nothing actionable here" and proceed
/// to do the wrong thing. Since ADR 0007 this also gates *execution* at tiers
/// 3–4, because a synthesized click lands on whatever is topmost at that point.
public enum WindowGuard {

  public struct WindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String
    public let title: String
    public let bounds: CGRect
    /// `kCGWindowLayer == 0` is a normal application window. Non-zero layers
    /// are menu bars, docks, overlays — including this agent's own cursor
    /// overlay, which must never be mistaken for a target.
    public let layer: Int
    public let isOnScreen: Bool
  }

  /// Every window the window server currently lists, excluding desktop elements.
  ///
  /// - Parameter onScreenOnly: the default, and what every caller acting on a
  ///   window wants. Pass `false` only to tell "this app has no window here"
  ///   apart from "this app is not running" — a minimized or off-Space window
  ///   is absent from the on-screen list and present in the full one, and
  ///   those two need different sentences.
  public static func windows(onScreenOnly: Bool = true) -> [WindowInfo] {
    var options: CGWindowListOption = [.excludeDesktopElements]
    if onScreenOnly { options.insert(.optionOnScreenOnly) }
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap { entry in
      guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { return nil }
      return WindowInfo(
        windowID: windowID,
        ownerPID: pid,
        ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
        title: entry[kCGWindowName as String] as? String ?? "",
        bounds: bounds,
        layer: entry[kCGWindowLayer as String] as? Int ?? 0,
        isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
      )
    }
  }

  /// An application name reduced to the part that identifies it.
  ///
  /// **WhatsApp reports its owner name as `U+200E` + `WhatsApp`** — a
  /// LEFT-TO-RIGHT MARK the window server carries through from the app's
  /// localized name, and which its own `CFBundleName` does not have. Measured
  /// on this machine: `e2 80 8e 57 68 61 74 73 41 70 70`. So an exact match on
  /// "WhatsApp" never found it, and the app was unaddressable by the only name
  /// anybody calls it.
  ///
  /// The character is invisible by construction. It does not appear in a window
  /// title, a screenshot, or a log line — the only way to see it is to hexdump
  /// the string, which is not where anyone starts looking when an app that is
  /// plainly on screen reports as "not running".
  ///
  /// Format characters (Unicode general category Cf — bidi marks, zero-width
  /// joiners, the BOM) are therefore dropped from both sides before comparing.
  /// They carry no identity; they exist to tell a text renderer what to do.
  public static func normalized(appName: String) -> String {
    String(appName.unicodeScalars.filter { $0.properties.generalCategory != .format })
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  /// Resolves an application name to its pid.
  ///
  /// Matches case-insensitively on the window owner name, preferring the owner
  /// with the largest on-screen window — an app with a stray 1×1 helper window
  /// should still resolve to the one the user can see.
  public static func pid(forApp name: String) throws -> pid_t {
    let wanted = normalized(appName: name)
    let matches = windows().filter {
      $0.layer == 0 && normalized(appName: $0.ownerName) == wanted
    }
    guard let best = matches.max(by: { $0.bounds.area < $1.bounds.area }) else {
      // **"Not running" and "running, but not here" are different problems
      // with different fixes, and one message for both sent a debugging
      // session after the wrong one.** Zen was running, listening on its
      // debug port and driving a page, with every window on another Space —
      // and `observe --app "Zen"` said it was not running. The next hour went
      // on case-sensitivity and name matching, neither of which was involved.
      //
      // The full window list answers it: a layer-0 window that exists but is
      // not on screen means the app is up and somewhere else.
      let elsewhere = windows(onScreenOnly: false).contains {
        $0.layer == 0 && normalized(appName: $0.ownerName) == wanted
      }
      throw elsewhere
        ? PerceptionError.windowNotOnScreen(app: name)
        : PerceptionError.appNotRunning(name)
    }
    return best.ownerPID
  }

  /// Whether this pid has a normal window the user can currently see.
  ///
  /// A window with zero area, or on a non-zero layer, does not count. Neither
  /// does one the window server no longer reports as on-screen.
  public static func hasVisibleWindow(pid: pid_t) -> Bool {
    windows().contains {
      $0.ownerPID == pid && $0.layer == 0 && $0.isOnScreen && $0.bounds.area > 0
    }
  }

  /// The largest visible window for a pid, or `nil`.
  public static func frontmostWindow(pid: pid_t) -> WindowInfo? {
    windows()
      .filter { $0.ownerPID == pid && $0.layer == 0 && $0.isOnScreen }
      .max(by: { $0.bounds.area < $1.bounds.area })
  }

  /// Fails loudly rather than letting an empty observation read as "nothing
  /// actionable here".
  public static func requireVisibleWindow(pid: pid_t, app: String) throws {
    guard hasVisibleWindow(pid: pid) else {
      throw PerceptionError.windowNotOnScreen(app: app)
    }
  }
}

extension CGRect {
  var area: CGFloat { width * height }
}
