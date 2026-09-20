import AppKit
import Foundation
import Harness

/// Argument parsing for the whole binary.
///
/// **The CLI is the product.** The skill files are thin wrappers over it — one
/// per host, a hundred lines of markdown each. When a skill file and
/// `docs/host-contract.md` disagree, the document is right; when the document
/// and this file disagree, that is a bug in this file.
enum CLI {

  enum Verb: String, CaseIterable {
    case run, resume, observe, act, overlay, help
  }

  struct Options {
    var verb: Verb = .help
    /// Set when argv[1] was not a verb. The host gets JSON, not prose.
    var unknownVerb: String?
    /// True only when a human explicitly asked for help.
    var helpRequested = false
    var task: String?
    var session: String?
    var planPath: String?
    var app: String?
    var kind: String?
    var target: String?
    var eyes: String?
    /// Text for `act --kind type`. Separate from `--eyes`, which carries a
    /// vision mark index and means something entirely different.
    var payload: String?
    /// Distinguishes an explicit `--label` from the overlay demo's default.
    var labelWasProvided = false
    var taskContext: String = ""
    var verbose = false
    /// Drive a browser instead of a native app. The agent launches its own on
    /// its own profile — it cannot attach to one you already have open, because
    /// the debug port is set at process start. ADR 0002.
    var browser = false

    // overlay-only
    var loop = false
    var speed: Double = 1.0
    var single: CGRect?
    var overlayVerb = "click"
    var label = "Send"
    var intent: CursorIntent = .routine
  }

  static func parse(_ argv: [String]) -> Options {
    var options = Options()
    guard argv.count > 1 else { return options }

    switch argv[1] {
    case "run": options.verb = .run
    case "resume": options.verb = .resume
    case "observe": options.verb = .observe
    case "act": options.verb = .act
    case "overlay": options.verb = .overlay
    case "--help", "-h", "help":
      options.helpRequested = true
      return options
    default:
      // An unrecognised verb is not silently reinterpreted. A host that
      // sends an unknown verb must learn that, not get different behaviour
      // — and it learns it in JSON, because stdout carries no prose.
      options.verb = .help
      options.unknownVerb = argv[1]
      return options
    }

    // `run` takes its task as the first positional argument.
    var index = 2
    if options.verb == .run, argv.count > 2, !argv[2].hasPrefix("--") {
      options.task = argv[2]
      index = 3
    }
    // `resume` takes its session id positionally.
    if options.verb == .resume, argv.count > 2, !argv[2].hasPrefix("--") {
      options.session = argv[2]
      index = 3
    }

    func next() -> String? { index + 1 < argv.count ? argv[index + 1] : nil }

    while index < argv.count {
      switch argv[index] {
      case "--plan":
        options.planPath = next()
        index += 1
      case "--session":
        options.session = next()
        index += 1
      case "--app":
        options.app = next()
        index += 1
      case "--kind":
        options.kind = next()
        index += 1
      case "--target":
        options.target = next()
        index += 1
      case "--eyes":
        options.eyes = next()
        index += 1
      case "--payload":
        options.payload = next()
        index += 1
      case "--label":
        // On `resume --eyes`, this is the vision label. `docs/host-contract.md`
        // §3.1 is explicit that it is not decoration: 74.2% of pressable
        // elements are icon-only, so without this string `LabelDenylist` has
        // nothing to match on for exactly those targets.
        options.label = next() ?? options.label
        options.labelWasProvided = true
        index += 1
      case "--context":
        options.taskContext = next() ?? ""
        index += 1
      case "--verbose": options.verbose = true
      case "--browser": options.browser = true
      case "--loop": options.loop = true
      case "--speed":
        if let value = next().flatMap(Double.init) { options.speed = max(0.1, min(value, 5)) }
        index += 1
      case "--at":
        // Fractions of the main display, so it reads the same on any screen.
        let parts = (next() ?? "").split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
          let screen = CGDisplayBounds(CGMainDisplayID())
          options.single = CGRect(
            x: screen.minX + screen.width * parts[0],
            y: screen.minY + screen.height * parts[1],
            width: 132, height: 34
          )
        }
        index += 1
      case "--verb":
        options.overlayVerb = next() ?? options.overlayVerb
        index += 1
      case "--danger": options.intent = .irreversible
      default: break
      }
      index += 1
    }
    return options
  }

  /// **There is no flag that approves an action.** Not `--yes`, not `--force`,
  /// not `--approved`. Page text reaches the host's context by construction,
  /// and a measured semantic reframing moved a Jev risk score from 0.98 to
  /// 0.42. Anything expressible as an argument is eventually expressible by an
  /// injected instruction. A window is not.
  ///
  /// Asserted by `SafetyTests`, not just written here.
  static let approvalFlags: Set<String> = []

  static let help = """
    open-agent — a computer-use agent driven by the coding agent you already run

      open-agent run "<task>" [--plan plan.json] [--app <name> | --browser]
                              [--context "<instance>"]
      open-agent resume <session> --eyes <n> --label "the send icon"
      open-agent resume <session> --eyes none
      open-agent resume <session> --plan plan.json
      open-agent observe --app <name> | --browser
      open-agent act --session <s> --kind <kind> --target e17 [--payload "text"]

      open-agent overlay                         scripted walkthrough, once
      open-agent overlay --loop                  repeat until Ctrl-C
      open-agent overlay --speed 0.4             slow the easing down
      open-agent overlay --at 0.8,0.2 \\
          --verb send --label "Send" --danger    one move + click, amber

    Every invocation prints one JSON object to stdout and exits. Logs go to
    stderr. Exit code is 0 for any status the host can act on, and non-zero only
    for a malformed invocation.

    Approval is not part of this interface. An irreversible action shows a native
    sheet and blocks until a human clicks it. There is no flag that answers it.

    Credentials: TYPESAFE_API_KEY in the environment, or the key on its own in
    ~/.config/open-agent/credentials (the vendor is TypeSafe; Jev is the model).
    The contract a host drives is docs/host-contract.md.
    """
}
