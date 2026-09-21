import Foundation
import Harness

/// `run` and `resume` state, on disk between invocations.
///
/// **Not a daemon.** A coding agent's tool calls are separate processes with
/// gaps between them, so a long-lived process would be one more thing to
/// supervise for no gain. The cost is that the warm Jev connection dies between
/// invocations and the first call after a resume pays the cold ~900 ms — that is
/// expected, and `docs/host-contract.md` §6 says so.
struct Session: Codable, Sendable {
  let id: String
  let task: String
  let taskContext: String
  var plan: Plan
  var appName: String
  /// Whether this task drives the browser. Carried so `resume` reconnects to
  /// the same world the task started in.
  var browser = false
  /// The site this task is about, when the plan does not say.
  ///
  /// The tab a browser run works in is settled from the plan's first
  /// `navigate` — that step names the site. A plan with no navigation names
  /// nothing, so the tab fell back to whichever one `resolveContext()` had
  /// guessed at connect time: measured, a scroll-only plan meant for a
  /// Facebook feed scrolled a blank tab nine times. `--url` is how such a
  /// plan says where it is. Persisted, because `resume` has to land in the
  /// same tab.
  ///
  /// Named `site`, not `url`: `url` on this type is already where the session
  /// is saved on disk.
  var site: String?
  var state: AgentLoop.LoopState
  /// What the last invocation was waiting for, so `resume` can refuse a
  /// session that is not waiting for anything.
  var waitingFor: HostStatus?
  /// Candidate ids as they were when the callback fired. `resume --eyes <n>`
  /// resolves against this, because the screen may have changed since.
  var candidates: [String: String]?

  static let directory: URL = {
    let base = FileManager.default
      .homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/open-agent/sessions")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()

  static func newID() -> String {
    // Sortable by creation, which makes `ls` on the session directory useful.
    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    let suffix = String(UInt32.random(in: 0..<UInt32.max), radix: 36)
    return "s_\(String(stamp, radix: 36))\(suffix)"
  }

  var url: URL { Self.directory.appending(path: "\(id).json") }

  func save() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  static func load(_ id: String) throws -> Session {
    let url = directory.appending(path: "\(id).json")
    guard let data = try? Data(contentsOf: url) else {
      throw LoopError.unknownSession(id)
    }
    return try JSONDecoder().decode(Session.self, from: data)
  }

  /// Where screenshots and step artifacts for this session live.
  var artifactsDirectory: URL {
    let url = Self.directory.appending(path: id)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
