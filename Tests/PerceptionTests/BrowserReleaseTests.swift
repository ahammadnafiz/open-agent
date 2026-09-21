import Foundation
import Testing

@testable import Harness

/// Handing the browser back when the agent is done with it.
///
/// **The agent leaves the user's daily browser in automation mode.** ADR 0011
/// drives the default profile so the agent inherits real logins, and the price
/// is a browser launched with `--remote-debugging-port`. Gecko sets
/// `navigator.webdriver` for the life of that process, paints a robot icon in
/// the URL bar and a "Browser is under remote control" notification under it.
/// Nothing turns that off at runtime — the port is a startup flag, ADR 0002 —
/// so the flag outlives the run that wanted it.
///
/// Measured 2026-09-21: a run finished at 13:16, and at 14:11 the same process
/// was still up. openai.com served a Cloudflare "Verify you are human"
/// interstitial and would not let the user through. From where they sat, the
/// agent had broken their browser.
///
/// Suppressing the banner is not the fix. The banner and the challenge are one
/// cause wearing two hats, and only the process exiting clears it.
@Suite("Browser release — regression")
struct BrowserReleaseTests {

  /// Records what the launcher did to the machine, in order.
  final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) {
      lock.lock()
      entries.append(entry)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }

  /// A profile path that is not the dedicated one, standing in for the user's
  /// own. The real default is read from `profiles.ini` and differs per machine,
  /// so naming it here would make these tests true only on one laptop.
  static let userProfile = "/tmp/oa-tests/Profiles/9ho70bff.Default (release)"

  static func probes(
    listening: Bool,
    journal: Journal,
    quitFails: Bool = false,
    restoreFails: Bool = false,
    exitTimesOut: Bool = false,
    comesBack: Bool = true
  ) -> BrowserLauncher.Probes {
    BrowserLauncher.Probes(
      isListening: { _ in listening },
      runningBrowsers: { _ in [] },
      binaryExists: { _ in true },
      quit: { _ in
        journal.record("quit")
        if quitFails { throw BrowserLauncher.LaunchError.couldNotQuit("Zen") }
      },
      waitForExit: { _, _ in
        journal.record("waitForExit")
        if exitTimesOut { throw BrowserLauncher.LaunchError.couldNotQuit("Zen") }
      },
      launch: { _, _, _ in
        journal.record("launch")
        return 4242
      },
      restoreLaunch: { _ in
        journal.record("restore")
        if restoreFails { throw BrowserLauncher.LaunchError.launchFailed("Zen") }
      },
      waitForLaunch: { _, _ in
        journal.record("waitForLaunch")
        return comesBack
      }
    )
  }

  /// The whole point: the flagged process goes, a clean one takes its place.
  @Test("a remote-controlled browser is quit and relaunched without the flag")
  func quitsAndRestores() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal)
    )
    #expect(released == .handedBack)
    #expect(journal.all == ["quit", "waitForExit", "restore", "waitForLaunch"])
    #expect(!journal.all.contains("launch"), "the restore must not re-open the debug port")
  }

  /// **The relaunch cannot overtake the quit.** A profile takes one process at
  /// a time, so a restore that starts before the old process has let go finds
  /// the profile locked and dies — leaving the user with no browser at all,
  /// which is worse than the banner this is meant to remove.
  @Test("the restore waits for the old process to exit")
  func waitsBeforeRelaunching() async {
    let journal = Journal()
    _ = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal)
    )
    let steps = journal.all
    #expect(steps.firstIndex(of: "waitForExit")! < steps.firstIndex(of: "restore")!)
  }

  /// **Idempotent, because a host will call it blindly.** Nothing on the port
  /// means no browser is under remote control, and quitting anyway would close
  /// a window the agent never opened.
  @Test("with nothing listening it does nothing at all")
  func noOpWhenNothingIsListening() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: false, journal: journal)
    )
    #expect(released == .nothingToHandBack)
    #expect(journal.all.isEmpty, "nothing was quit and nothing was launched")
  }

  /// **The dedicated profile is not the user's browser.** In that mode the
  /// agent runs its own second copy of Zen, and the user's stays untouched and
  /// unflagged — so there is nothing to hand back. Quitting would be worse than
  /// useless: `tell application "Zen" to quit` is app-wide, not profile-scoped,
  /// so it would close the browser the user is reading right now to tidy up a
  /// process that was never in their way.
  @Test("on the dedicated profile it leaves everything alone")
  func noOpOnDedicatedProfile() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Constants.Browser.dedicatedProfilePath,
      probes: Self.probes(listening: true, journal: journal)
    )
    #expect(released == .nothingToHandBack)
    #expect(journal.all.isEmpty, "the user's browser is not ours to quit in this mode")
  }

  /// **A failed restore must not fail the task.** This runs after the work is
  /// finished and reported; turning a completed send into an error because a
  /// browser would not reopen would be lying about the thing the user asked
  /// for.
  @Test("a quit that fails is reported, not thrown")
  func quitFailureIsSwallowed() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal, quitFails: true)
    )
    guard case .failed(let why) = released else {
      Issue.record("expected a reported failure, got \(released)")
      return
    }
    #expect(why.contains("still under remote control"))
    #expect(journal.all == ["quit"], "it stopped rather than relaunching over a live process")
  }

  @Test("a relaunch that fails is reported, not thrown")
  func restoreFailureIsSwallowed() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal, restoreFails: true)
    )
    guard case .failed(let why) = released else {
      Issue.record("expected a reported failure, got \(released)")
      return
    }
    #expect(why.contains("would not reopen"), "it must say the browser is gone, not still flagged")
    #expect(journal.all == ["quit", "waitForExit", "restore"])
  }

  /// **A slow quit must not cost the user their browser.**
  ///
  /// The first version treated the wait timing out as a reason to give up: it
  /// threw at `quitTimeout`, the catch returned, and nothing relaunched. But the
  /// quit had already been asked for — so a browser that took nine seconds to
  /// save its session exited into an empty desktop. That is precisely the
  /// failure the wait was added to prevent, arriving through the wait itself.
  ///
  /// Past the quit, a timeout is late, not fatal.
  @Test("a quit that outruns the timeout is still reopened")
  func slowQuitIsStillReopened() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal, exitTimesOut: true)
    )
    #expect(released == .handedBack)
    #expect(
      journal.all.contains("restore"),
      "the browser was told to quit, so it MUST be reopened — a timeout is late, not fatal")
  }

  /// **A relaunch issued while the old process is still quitting is swallowed.**
  /// `open` succeeds, the dying process takes the app slot with it, and nothing
  /// says so at the time — so the only way to know is to look afterwards.
  @Test("a relaunch that raced the quit is retried")
  func racedRelaunchIsRetried() async {
    let journal = Journal()
    let released = await BrowserLauncher.release(
      profileOverride: Self.userProfile,
      probes: Self.probes(listening: true, journal: journal, comesBack: false)
    )
    #expect(journal.all.filter { $0 == "restore" }.count == 2, "it tried again")
    guard case .failed(let why) = released else {
      Issue.record("expected a reported failure, got \(released)")
      return
    }
    #expect(why.contains("did not come back"))
  }
}

/// Which statuses mean the host is finished with the browser.
///
/// **This is the whole decision behind the automatic release**, so it is tested
/// where it is decided rather than inside the command that acts on it.
@Suite("Session-ending statuses")
struct SessionEndingStatusTests {

  /// `needs_eyes` and `needs_plan` are the two callbacks that exist precisely
  /// so the host can come back — SPEC.md § Boundaries. Restarting the browser
  /// between a `needs_plan` and its resume would throw away the tab the run was
  /// working in and reload the rest unloaded, which is the state that made the
  /// *next* observation report the site as not open either.
  @Test("the two resume callbacks keep the browser")
  func callbacksKeepTheBrowser() {
    #expect(HostStatus.needsEyes.isTerminal == false)
    #expect(HostStatus.needsPlan.isTerminal == false)
  }

  /// `blocked` is terminal by construction — "retrying a login wall produces
  /// another login wall" — so it hands the browser back like any other ending.
  /// It is also the status a Cloudflare challenge produces, which is the exact
  /// wall an unreleased browser builds for the next run.
  @Test("every terminal status hands the browser back")
  func terminalStatusesRelease() {
    for status in [
      HostStatus.completed, .failed, .blocked, .unverified, .budgetExhausted,
    ] {
      #expect(status.isTerminal, "\(status.rawValue) is terminal")
    }
  }

  /// A seventh case is an "ask first" boundary on the status enum itself, and
  /// it is one here too: the switch is exhaustive on purpose, so a new status
  /// cannot be added without someone deciding whether it gives the browser
  /// back.
  @Test("every status has an answer")
  func everyStatusIsClassified() {
    #expect(HostStatus.allCases.count == 7)
    let ending = HostStatus.allCases.filter(\.isTerminal)
    #expect(ending.count == 5)
  }
}
