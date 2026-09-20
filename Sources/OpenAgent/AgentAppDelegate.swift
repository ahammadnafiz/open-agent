import AppKit
import Harness

/// Hosts the run loop for the verbs that need one.
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
  private let options: CLI.Options

  init(options: CLI.Options) {
    self.options = options
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let options = self.options
    Task { @MainActor in
      switch options.verb {
      case .overlay:
        await CursorDemo.run(options)
        if !options.loop { NSApp.terminate(nil) }
      case .run:
        await Commands.run(options)
        NSApp.terminate(nil)
      case .resume:
        await Commands.resume(options)
        NSApp.terminate(nil)
      default:
        NSApp.terminate(nil)
      }
    }
  }
}
