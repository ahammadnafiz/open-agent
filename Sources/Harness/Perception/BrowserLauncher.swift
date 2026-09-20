import Foundation

/// Launches, and where necessary restarts, the browser the agent drives.
///
/// Two constraints shape everything here, and neither has a way around it:
///
/// 1. **`--remote-debugging-port` is a startup flag.** Gecko has no runtime
///    equivalent, so a browser that is already running cannot be told to start
///    listening. It has to be relaunched.
/// 2. **A profile takes one process at a time.** So driving the profile you
///    actually use means your running browser quits first.
///
/// The consequence people meet is a browser restart, once. The alternative —
/// a dedicated empty profile — avoids the restart and is logged into nothing,
/// which is why it is no longer the default. ADR 0011.
public enum BrowserLauncher {

  public struct Handle: Sendable {
    public let processIdentifier: Int32
    public let port: Int
    public let profile: String
    /// True when an existing browser had to be quit to free the profile.
    public let restartedExistingBrowser: Bool
  }

  public enum LaunchError: Error, Equatable, Sendable {
    case binaryMissing(String)
    case profileLocked(String)
    case couldNotQuit(String)
    case launchFailed(String)
  }

  /// The operating-system facts `ensureDrivable` reasons about.
  ///
  /// Injected so the launch *decision* can be tested without a browser. The
  /// decision is the part that went wrong: the first version launched on every
  /// failed connect, which is what stacked empty windows beside the browser the
  /// user was working in. That is a branch, and a branch belongs in a test.
  public struct Probes: Sendable {
    public var isListening: @Sendable (Int) -> Bool
    public var runningBrowsers: @Sendable (String) -> [Int32]
    public var binaryExists: @Sendable (String) -> Bool
    public var quit: @Sendable (String) throws -> Void
    public var waitForExit: @Sendable (String, Duration) async throws -> Void
    /// Returns the pid of the browser it started.
    public var launch: @Sendable (String, String, Int) throws -> Int32

    public init(
      isListening: @escaping @Sendable (Int) -> Bool,
      runningBrowsers: @escaping @Sendable (String) -> [Int32],
      binaryExists: @escaping @Sendable (String) -> Bool,
      quit: @escaping @Sendable (String) throws -> Void,
      waitForExit: @escaping @Sendable (String, Duration) async throws -> Void,
      launch: @escaping @Sendable (String, String, Int) throws -> Int32
    ) {
      self.isListening = isListening
      self.runningBrowsers = runningBrowsers
      self.binaryExists = binaryExists
      self.quit = quit
      self.waitForExit = waitForExit
      self.launch = launch
    }

    public static let live = Probes(
      isListening: { BrowserLauncher.isListening(port: $0) },
      runningBrowsers: { BrowserLauncher.runningBrowsers(binary: $0) },
      binaryExists: { FileManager.default.fileExists(atPath: $0) },
      quit: { try BrowserLauncher.quitGracefully(applicationName: $0) },
      waitForExit: { try await BrowserLauncher.waitForExit(binary: $0, deadline: $1) },
      launch: { binary, profile, port in
        try FileManager.default.createDirectory(
          atPath: profile, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments =
          Constants.Browser.launchArgs + [
            "--remote-debugging-port", "\(port)", "--profile", profile,
          ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LaunchError.launchFailed("\(error)") }
        return process.processIdentifier
      }
    )
  }

  // MARK: - Process discovery

  /// PIDs of running browser processes for this binary, parents only.
  ///
  /// Gecko forks a `plugin-container` per tab; those share the executable path
  /// prefix and must not be counted as browsers, or a quit looks like it failed.
  static func runningBrowsers(binary: String) -> [Int32] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return String(decoding: data, as: UTF8.self)
      .components(separatedBy: .newlines)
      .compactMap { line -> Int32? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let command = String(trimmed[trimmed.index(after: space)...])
        guard command.hasPrefix(binary) else { return nil }
        guard !command.contains("plugin-container") else { return nil }
        return Int32(trimmed[trimmed.startIndex..<space])
      }
  }

  /// Whether the browser is already listening for BiDi.
  static func isListening(port: Int) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return !String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - The one entry point

  /// Makes the browser drivable, restarting it if that is the only way.
  ///
  /// - Parameter allowRestart: when false, a browser running without a debug
  ///   port is an error rather than something to quit. The agent should never
  ///   close a window the user is working in without that being the explicit
  ///   deal, so this is a decision the caller makes, not this function.
  public static func ensureDrivable(
    binary: String = Constants.Browser.zenBinary,
    profileOverride: String? = nil,
    port: Int = Constants.Browser.bidiPort,
    allowRestart: Bool,
    probes: Probes = .live
  ) async throws -> Handle {
    guard probes.binaryExists(binary) else {
      throw LaunchError.binaryMissing(binary)
    }
    let profile = BrowserProfile.active(override: profileOverride)

    // Already drivable. Attach; do NOT start a second browser.
    //
    // This check is the whole fix for the stacked-windows bug. Connecting has
    // its own retry loop, and when launching lived inside that loop every
    // failed attempt started another browser — each one grabbing a profile,
    // none of them reachable.
    if probes.isListening(port) {
      Log.info("attaching to the browser already listening on port \(port)")
      return Handle(
        processIdentifier: probes.runningBrowsers(binary).first ?? 0,
        port: port, profile: profile, restartedExistingBrowser: false
      )
    }

    let running = probes.runningBrowsers(binary)
    var restarted = false

    if !running.isEmpty {
      // A browser is up but has no debug port, and the port cannot be added to
      // a running process. The only way through is a restart, and that closes a
      // window the user may be working in — so it is the caller's call, never a
      // silent default in here.
      guard allowRestart else {
        throw LaunchError.profileLocked(profile)
      }
      // Quit through the application, not with a signal. Gecko saves session
      // state on a clean quit, so the tabs come back; a SIGKILL loses them and
      // leaves the profile lock behind.
      Log.info("quitting the running browser so its profile can be driven")
      try probes.quit("Zen")
      try await probes.waitForExit(binary, Constants.Browser.quitTimeout)
      restarted = true
    }

    let pid = try probes.launch(binary, profile, port)
    Log.info("launched browser pid \(pid) on port \(port)")
    Log.info("profile: \(profile)")

    return Handle(
      processIdentifier: pid, port: port,
      profile: profile, restartedExistingBrowser: restarted
    )
  }

  /// `tell application "X" to quit` — the same thing ⌘Q does, so the session is
  /// saved and restored on the next launch.
  static func quitGracefully(applicationName: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"\(applicationName)\" to quit"]
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw LaunchError.couldNotQuit(applicationName)
    }
  }

  static func waitForExit(binary: String, deadline: Duration) async throws {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
      if runningBrowsers(binary: binary).isEmpty { return }
      try? await Task.sleep(for: .milliseconds(250))
    }
    throw LaunchError.couldNotQuit(binary)
  }

  /// Opens a profile for a human to log into a site by hand.
  ///
  /// Only needed for the dedicated-profile mode, where the agent starts logged
  /// into nothing. Driving the default profile makes this unnecessary, which is
  /// the entire reason the default changed.
  public static func loginSession(
    binary: String = Constants.Browser.zenBinary,
    profileOverride: String? = nil
  ) throws {
    let profile = BrowserProfile.active(override: profileOverride)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = Constants.Browser.launchArgs + ["--profile", profile]
    try process.run()
    process.waitUntilExit()
  }
}
