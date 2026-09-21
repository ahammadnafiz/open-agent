import AppKit
import Harness

// The CLI is the product — `docs/host-contract.md`. Every invocation prints one
// JSON object to stdout and exits; logs go to stderr; the exit code is 0 for any
// status the host can act on and non-zero only for a malformed invocation, so a
// host never has to parse prose.

let options = CLI.parse(CommandLine.arguments)
Log.minimumLevel = options.verbose ? .debug : .info

switch options.verb {
case .help:
  if let unknown = options.unknownVerb {
    // stdout stays JSON-only; the human-readable help goes to stderr with
    // the rest of the logs.
    FileHandle.standardError.write(Data((CLI.help + "\n").utf8))
    Commands.fail(
      "unknown verb '\(unknown)' — expected one of: "
        + "run, resume, observe, act, overlay, release")
  }
  // A human asked. Prose is the right answer, and there is no host to confuse.
  print(CLI.help)
  exit(0)

case .overlay, .run, .resume:
  // These need an application run loop: the overlay draws, and `run`/`resume`
  // may put up the approval sheet, which is a real window a human clicks.
  let delegate = AgentAppDelegate(options: options)
  NSApplication.shared.delegate = delegate
  NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon, no menu bar
  NSApplication.shared.run()

case .observe, .act, .release:
  // No pixels, no sheet, no run loop. `observe` in particular is the skill's
  // own smoke test and must work with nothing on screen.
  await Commands.runHeadless(options)
}
