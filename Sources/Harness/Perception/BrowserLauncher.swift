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

  /// The application's name, as the operating system knows it, derived from
  /// the binary path.
  ///
  /// **So the logs can say which browser.** Every line here used to read "the
  /// browser", and the one that quits it hardcoded `"Zen"` while the binary it
  /// waited on was a parameter — two different browsers in one function. A
  /// person watching Chrome while Zen quits behind it has no way to tell what
  /// just happened, and that is the confusion this removes.
  ///
  /// `/Applications/Zen.app/Contents/MacOS/zen` → `Zen`.
  static func appName(of binary: String) -> String {
    for component in (binary as NSString).pathComponents.reversed()
    where component.hasSuffix(".app") {
      return String(component.dropLast(".app".count))
    }
    return (binary as NSString).lastPathComponent
  }

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
    /// Reopens the browser the way a person does, by application name and with
    /// no debug port. Deliberately *not* `launch` with the flags left off:
    /// this is the ordinary launch that hands the browser back, and the two
    /// must not be one function that a boolean could get backwards.
    public var restoreLaunch: @Sendable (String) throws -> Void
    /// Whether a browser process came back within the deadline.
    ///
    /// The mirror of `waitForExit`, and it exists for one case: a relaunch
    /// issued while the old process was still quitting is swallowed, and the
    /// only way to know is to look afterwards. Reports rather than throws —
    /// "it did not come back" is an answer `release` acts on, not an error.
    public var waitForLaunch: @Sendable (String, Duration) async -> Bool

    public init(
      isListening: @escaping @Sendable (Int) -> Bool,
      runningBrowsers: @escaping @Sendable (String) -> [Int32],
      binaryExists: @escaping @Sendable (String) -> Bool,
      quit: @escaping @Sendable (String) throws -> Void,
      waitForExit: @escaping @Sendable (String, Duration) async throws -> Void,
      launch: @escaping @Sendable (String, String, Int) throws -> Int32,
      restoreLaunch: @escaping @Sendable (String) throws -> Void,
      waitForLaunch: @escaping @Sendable (String, Duration) async -> Bool
    ) {
      self.isListening = isListening
      self.runningBrowsers = runningBrowsers
      self.binaryExists = binaryExists
      self.quit = quit
      self.waitForExit = waitForExit
      self.launch = launch
      self.restoreLaunch = restoreLaunch
      self.waitForLaunch = waitForLaunch
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
      },
      restoreLaunch: { try BrowserLauncher.restoreGracefully(applicationName: $0) },
      waitForLaunch: { await BrowserLauncher.waitForLaunch(binary: $0, deadline: $1) }
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
    /// Restart even when the port is already answering.
    ///
    /// For the one case where a listening port is not enough: the browser holds
    /// a WebDriver session for a connection that no longer exists, and only its
    /// own exit will release it. See `BiDiError.sessionHeldElsewhere`.
    forceRestart: Bool = false,
    probes: Probes = .live
  ) async throws -> Handle {
    guard probes.binaryExists(binary) else {
      throw LaunchError.binaryMissing(binary)
    }
    let profile = BrowserProfile.active(override: profileOverride)
    let browser = appName(of: binary)

    // Already drivable. Attach; do NOT start a second browser.
    //
    // This check is the whole fix for the stacked-windows bug. Connecting has
    // its own retry loop, and when launching lived inside that loop every
    // failed attempt started another browser — each one grabbing a profile,
    // none of them reachable.
    if probes.isListening(port), !forceRestart {
      Log.info("attaching to \(browser), already listening on port \(port)")
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
      Log.info("quitting \(browser) so its profile can be driven")
      // The name comes from the binary being launched, not a literal. These
      // were allowed to disagree, and a quit aimed at one browser while
      // waiting on another cannot ever succeed.
      try probes.quit(browser)
      try await probes.waitForExit(binary, Constants.Browser.quitTimeout)
      restarted = true
    }

    let pid = try probes.launch(binary, profile, port)
    Log.info("launched \(browser) pid \(pid) on port \(port)")
    Log.info("profile: \(profile)")

    return Handle(
      processIdentifier: pid, port: port,
      profile: profile, restartedExistingBrowser: restarted
    )
  }

  // MARK: - Giving it back

  /// Ends remote control and reopens the browser as the user's own.
  ///
  /// **The agent borrows the browser; this is the half that returns it.**
  /// `ensureDrivable` launches with `--remote-debugging-port`, and Gecko treats
  /// that as a property of the process: `navigator.webdriver` is true for its
  /// whole life, the URL bar carries a robot icon and a "Browser is under
  /// remote control" notification, and there is no runtime switch to undo any
  /// of it — the port is a startup flag, ADR 0002. So the flag outlived every
  /// run that asked for it.
  ///
  /// What that cost, measured 2026-09-21: a run ended at 13:16 and its browser
  /// was still up at 14:11, by which point openai.com was serving the user a
  /// Cloudflare "Verify you are human" wall on their own machine. The banner and
  /// the wall are one cause wearing two hats — bot detection reads
  /// `navigator.webdriver` — so hiding the banner would have left the wall. Only
  /// the process ending clears it, which means a quit and a plain relaunch.
  ///
  /// The quit is the graceful one `ensureDrivable` already uses, so Gecko writes
  /// its session and the tabs come back.
  ///
  /// What a hand-back did, which is three outcomes and not two.
  ///
  /// **A `Bool` conflated "there was nothing to do" with "I tried and could
  /// not".** The `release` verb reported the second as the first — `completed`,
  /// with the reason *"no browser was under remote control"* — while the only
  /// truthful account went to stderr, which `docs/host-contract.md` forbids the
  /// host from reading. A host cannot act on a failure it is told did not
  /// happen, and this is exactly the state the user has to know about: their
  /// browser is still flagged.
  public enum Outcome: Sendable, Equatable {
    /// Quit and reopened without a debug port.
    case handedBack
    /// Nothing was under remote control. Already the user's.
    case nothingToHandBack
    /// The hand-back was attempted and did not complete. Carries the sentence a
    /// human needs to finish it themselves.
    case failed(String)
  }

  /// Ends remote control and reopens the browser as the user's own.
  ///
  /// - Returns: what happened. **Never throws.** This runs after the work is
  ///   done and reported, and a browser that will not reopen is not a reason to
  ///   call a finished task failed.
  @discardableResult
  public static func release(
    binary: String = Constants.Browser.zenBinary,
    profileOverride: String? = nil,
    port: Int = Constants.Browser.bidiPort,
    probes: Probes = .live
  ) async -> Outcome {
    let profile = BrowserProfile.active(override: profileOverride)
    let browser = appName(of: binary)

    // On the dedicated profile the agent runs its own second copy and the
    // user's browser was never flagged, so there is nothing of theirs to give
    // back. Quitting anyway would be actively wrong: `tell application "Zen" to
    // quit` is app-wide, not profile-scoped, so tidying up the agent's process
    // would close the window the user is reading.
    guard profile != Constants.Browser.dedicatedProfilePath else {
      Log.debug("release: dedicated profile, the user's browser was never driven")
      return .nothingToHandBack
    }

    // Nothing answering on the port means nothing is under remote control.
    // A host may call this blindly, and twice in a row must not cost a second
    // restart of a browser that is already clean.
    guard probes.isListening(port) else {
      Log.debug("release: nothing listening on port \(port), nothing to hand back")
      return .nothingToHandBack
    }

    Log.info("handing \(browser) back: quitting the remote-controlled process")

    // Before the quit is asked for, bailing out is free — the browser is
    // untouched and still the user's, flagged but present.
    do {
      try probes.quit(browser)
    } catch {
      return failure(
        "could not ask \(browser) to quit (\(error)). It is still under remote control — "
          + "quit it and reopen it to clear that.")
    }

    // **Past this line the browser is going to exit, so it MUST be reopened.**
    // The first version treated a slow quit as a reason to give up: the wait
    // threw at 8s, the catch returned, and nothing relaunched — so a browser
    // that took nine seconds to save its session exited into an empty desktop.
    // That is the failure the wait was added to prevent, arriving through the
    // wait itself. A timeout here is late, not fatal.
    do {
      try await probes.waitForExit(binary, Constants.Browser.quitTimeout)
    } catch {
      Log.warn("\(browser) is taking longer than \(Constants.Browser.quitTimeout) to quit")
    }

    do {
      try probes.restoreLaunch(browser)
    } catch {
      return failure(
        "\(browser) was quit but would not reopen (\(error)). Open it yourself — "
          + "its tabs are saved and will come back.")
    }

    // **A relaunch issued while the old process was still quitting is
    // swallowed**, and nothing says so at the time: `open` succeeds, the dying
    // process takes the app slot with it, and the desktop ends up empty. The
    // only way to know is to look afterwards, so this looks.
    if await probes.waitForLaunch(binary, Constants.Browser.launchTimeout) {
      Log.info("\(browser) reopened without a debug port; the session restores its tabs")
      return .handedBack
    }

    Log.warn("\(browser) did not come back — the relaunch raced its quit. Trying once more.")
    do {
      try probes.restoreLaunch(browser)
    } catch {
      return failure("\(browser) was quit and would not reopen (\(error)). Open it yourself.")
    }
    guard await probes.waitForLaunch(binary, Constants.Browser.launchTimeout) else {
      return failure("\(browser) was quit and did not come back. Open it yourself.")
    }
    Log.info("\(browser) reopened without a debug port; the session restores its tabs")
    return .handedBack
  }

  /// Logs the sentence and returns it, so the two never drift apart.
  private static func failure(_ reason: String) -> Outcome {
    Log.warn(reason)
    return .failed(reason)
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
    // **A failed `osascript` used to report success**, and the cost was paid by
    // the wait that follows: nothing had been asked to quit, so the full
    // `quitTimeout` elapsed before anything said so. Telling the truth here
    // turns eight silent seconds into one accurate error.
    //
    // Quitting an application that is not running is not a failure — osascript
    // exits 0 for it — so this only fires on a real one.
    guard process.terminationStatus == 0 else {
      throw LaunchError.couldNotQuit(
        "\(applicationName) (osascript exited \(process.terminationStatus))")
    }
  }

  /// `open -a X` — the launch a person's own double-click performs.
  ///
  /// **Not `Process` on the binary, the way `launch` does it.** That spawns the
  /// browser as a child of this short-lived CLI, with our environment and our
  /// session; `open` hands the request to LaunchServices, which starts it as a
  /// normal foreground application exactly as the Dock would. The browser being
  /// given back has to be indistinguishable from one the user started, and the
  /// launch path is part of what makes it so.
  ///
  /// No arguments beyond the name. Every flag here is one the user did not ask
  /// for, and the profile needs no naming — opened plainly, the browser goes to
  /// the same default it always does.
  static func restoreGracefully(applicationName: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", applicationName]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw LaunchError.launchFailed("could not run open -a \(applicationName): \(error)")
    }
    // `open` returns non-zero when it could not start the application at all.
    // Letting that pass silently would report a hand-back that never happened.
    //
    // The two failures carry different text on purpose: one means `open` never
    // ran, the other means it ran and refused, and a single shared payload made
    // them indistinguishable in the one place a human reads them.
    guard process.terminationStatus == 0 else {
      throw LaunchError.launchFailed(
        "open -a \(applicationName) exited \(process.terminationStatus)")
    }
  }

  /// Polls until a browser process exists, or the deadline passes.
  ///
  /// The mirror of `waitForExit`, and it reports rather than throwing: "it did
  /// not come back" is a state `release` acts on by trying again, not an error
  /// to unwind.
  static func waitForLaunch(binary: String, deadline: Duration) async -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
      if !runningBrowsers(binary: binary).isEmpty { return true }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return !runningBrowsers(binary: binary).isEmpty
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
