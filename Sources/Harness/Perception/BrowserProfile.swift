import Foundation

/// Which Zen profile the agent drives.
///
/// Reads `profiles.ini` rather than hard-coding a path: profile directory names
/// are randomised per install (`9ho70bff.Default (release)`), so a literal path
/// works on exactly one machine.
public enum BrowserProfile {

  /// The profile Zen opens on its own, as `profiles.ini` declares it.
  ///
  /// `[InstallXXXX] Default=` wins when present — that is the per-install
  /// default Firefox and its forks actually honour, and it is why a plain
  /// `Default=1` under a `[ProfileN]` section can point somewhere the browser
  /// never opens. On this machine the two disagree, which is exactly the case
  /// that makes reading the file worth doing.
  public static func resolveDefault(
    root: String = Constants.Browser.profilesRoot
  ) -> String? {
    let iniPath = (root as NSString).appendingPathComponent("profiles.ini")
    guard let contents = try? String(contentsOfFile: iniPath, encoding: .utf8) else {
      return nil
    }

    var sections: [String: [String: String]] = [:]
    var current = ""
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") && line.hasSuffix("]") {
        current = String(line.dropFirst().dropLast())
        sections[current] = [:]
        continue
      }
      guard let separator = line.firstIndex(of: "="), !current.isEmpty else { continue }
      let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      sections[current]?[key] = value
    }

    func absolute(_ relative: String) -> String {
      relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
    }

    // 1. The per-install default. This is the authoritative one.
    for (name, values) in sections where name.hasPrefix("Install") {
      if let path = values["Default"] { return absolute(path) }
    }
    // 2. A profile section flagged Default=1.
    for (name, values) in sections where name.hasPrefix("Profile") {
      _ = name
      if values["Default"] == "1", let path = values["Path"] { return absolute(path) }
    }
    // 3. The first profile listed.
    for (name, values) in sections.sorted(by: { $0.key < $1.key }) where name.hasPrefix("Profile") {
      if let path = values["Path"] { return absolute(path) }
    }
    return nil
  }

  /// The profile the agent should use, honouring
  /// `Constants.Browser.useDefaultProfile`.
  public static func active(override explicit: String? = nil) -> String {
    if let explicit { return (explicit as NSString).expandingTildeInPath }
    if Constants.Browser.useDefaultProfile, let resolved = resolveDefault() {
      return resolved
    }
    return Constants.Browser.dedicatedProfilePath
  }

  /// Whether some process currently holds this profile's lock.
  ///
  /// Gecko writes `parent.lock` and a `.parentlock` symlink. A profile in use
  /// cannot be opened by a second process, which is why driving the real
  /// profile means quitting the browser first rather than running alongside it.
  public static func isLocked(_ profile: String) -> Bool {
    let manager = FileManager.default
    for name in ["parent.lock", ".parentlock", "lock"] {
      if manager.fileExists(atPath: (profile as NSString).appendingPathComponent(name)) {
        return true
      }
    }
    return false
  }
}
