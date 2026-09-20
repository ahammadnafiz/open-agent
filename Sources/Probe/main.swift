import Foundation
import Harness

// Live probes against the real APIs.
//
// Deliberately NOT part of `swift test`. The interesting failure modes of this
// system are in live API behaviour, not in pure logic, and those cannot live in
// the test suite without making it slow and flaky — and a test suite that needs
// an API key and a browser is a test suite people stop running.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
  print(Probe.help)
  exit(0)
}

Log.minimumLevel = .debug

switch arguments[1] {
case "jev-latency": await Probe.jevLatency()
case "jev-budget": await Probe.jevBudget(app: arguments.count > 2 ? arguments[2] : "Finder")
case "ax-tree": await Probe.axTree(app: arguments.count > 2 ? arguments[2] : "Finder")
case "windows": Probe.windows()
case "--help", "-h": print(Probe.help)
default:
  FileHandle.standardError.write(Data("unknown probe '\(arguments[1])'\n\n".utf8))
  print(Probe.help)
  exit(2)
}

enum Probe {
  static let help = """
    Probe — live checks against the real APIs. Needs TYPESAFE_API_KEY.

      swift run Probe jev-latency          warm vs cold round trip
      swift run Probe jev-budget [app]     token cost of a real candidate set
      swift run Probe ax-tree [app]        what tier 2 actually sees
      swift run Probe windows              what the window server reports

    Not yet implemented (needs a labelled fixture set first):
      battery-eval       every question x 5 repeats, straddle detection
      captured-eval      tier 3/4 hit rate — Open Question Q7
    """

  // MARK: - jev-latency

  /// Measures the warm-connection claim: **383 ms warm vs ~900 ms cold**,
  /// because TLS and TCP setup to the vendor's edge costs ~520 ms.
  ///
  /// A session spans several `run`/`resume` invocations, which are separate
  /// processes, so the warm connection dies between them and the first call
  /// after a resume pays cold. Budget for it; do not read it as a regression.
  static func jevLatency() async {
    guard let client = makeClient() else { return }
    let context = sampleContext(candidates: ["e0": "New mail", "e1": "Archive", "e2": "Reply"])

    print("call  status      ms")
    print("────  ──────────  ─────")
    var timings: [Double] = []
    for call in 1...5 {
      let started = ContinuousClock.now
      do {
        let verdict = try await client.step(context)
        let ms = (ContinuousClock.now - started).inSeconds * 1000
        timings.append(ms)
        print(
          "\(pad("\(call)", 4, right: true))  ok \(pad(verdict.modelVersion, 12)) \(pad(fmt(ms, 0), 5, right: true))"
        )
      } catch {
        let ms = (ContinuousClock.now - started).inSeconds * 1000
        print(
          "\(pad("\(call)", 4, right: true))  FAILED       \(pad(fmt(ms, 0), 5, right: true))  \(error)"
        )
        return
      }
    }
    if let cold = timings.first, timings.count > 1 {
      let warm = timings.dropFirst().reduce(0, +) / Double(timings.count - 1)
      print(
        "\ncold \(fmt(cold, 0)) ms · warm mean \(fmt(warm, 0)) ms · delta \(fmt(cold - warm, 0)) ms"
      )
      print("docs claim: 383 ms warm, ~900 ms cold, ~520 ms of it TLS + TCP setup")
    }
  }

  // MARK: - jev-budget

  /// Answers the open question the plan flagged: **what does a real candidate
  /// set actually cost in tokens?**
  ///
  /// The documented ceiling is 32k for `state` plus the longest question. The
  /// preflight in `JevClient` uses a 4-characters-per-token heuristic; this
  /// replaces that guess with a measurement from the vendor's own `usage`.
  static func jevBudget(app: String) async {
    guard let client = makeClient() else { return }
    do {
      let source = try AXSource(appName: app)
      let candidates = try CandidateFilter.reduce(try await source.observe())
      let context = sampleContext(candidates: candidates.criteria)

      let estimated =
        (try? JSONEncoder().encode(context).count).map {
          $0 / Constants.Jev.charactersPerTokenEstimate
        } ?? 0

      let verdict = try await client.step(context)
      print("app                \(app)")
      print("candidates         \(candidates.count)")
      print(
        "estimated tokens   \(estimated)  (heuristic: \(Constants.Jev.charactersPerTokenEstimate) chars/token)"
      )
      print("actual input       \(verdict.usage.inputTokens)")
      print("actual output      \(verdict.usage.outputTokens)  (free)")
      print("cost               $\(fmt(verdict.usage.dollars, 6))")
      print("state ceiling      \(Constants.Jev.stateTokenLimit)")
      let ratio = Double(verdict.usage.inputTokens) / Double(max(estimated, 1))
      print("\nheuristic is \(fmt(ratio, 2))x the real count")
      if candidates.count > 0 {
        let perCandidate = Double(verdict.usage.inputTokens) / Double(candidates.count)
        print(
          "≈ \(fmt(perCandidate, 1)) tokens per candidate → 255 candidates ≈ \(fmt(perCandidate * 255, 0)) tokens"
        )
      }
    } catch {
      fail(error)
    }
  }

  // MARK: - ax-tree

  /// What tier 2 actually sees, with the numbers to compare against
  /// `docs/element-sources.md`: Finder 909 nodes / 116 pressable / 91 labelled.
  static func axTree(app: String) async {
    do {
      let started = ContinuousClock.now
      let source = try AXSource(appName: app)
      let elements = try await source.observe()
      let elapsed = ContinuousClock.now - started
      let candidates = try CandidateFilter.reduce(elements)

      print("app              \(app)  (pid \(source.pid))")
      print("walk             \(fmt(elapsed.inSeconds, 2)) s")
      print("labelled+actionable  \(elements.count)")
      print("survived the filter  \(candidates.count)")
      print("")
      for (index, element) in candidates.elements.prefix(40).enumerated() {
        print("  \(pad("e\(index)", 5))\(pad(element.role, 20))\(element.label)")
      }
      if candidates.count > 40 { print("  … \(candidates.count - 40) more") }
    } catch {
      fail(error)
    }
  }

  // MARK: - windows

  static func windows() {
    print("pid     layer  on  area        owner / title")
    for window in WindowGuard.windows().sorted(by: { $0.ownerName < $1.ownerName }) {
      let area = window.bounds.width * window.bounds.height
      print(
        pad("\(window.ownerPID)", 8) + pad("\(window.layer)", 7)
          + pad(window.isOnScreen ? "y" : "n", 4) + pad(fmt(area, 0), 12)
          + window.ownerName + (window.title.isEmpty ? "" : " — \(window.title)")
      )
    }
  }

  // MARK: - Helpers

  private static func makeClient() -> JevClient? {
    do {
      return try JevClient()
    } catch {
      FileHandle.standardError.write(Data((Credentials.missingKeyGuidance + "\n").utf8))
      exit(2)
    }
  }

  private static func sampleContext(candidates: [String: String]) -> StepContext {
    StepContext(
      task: "reply to the most recent message and send it",
      planStep: PlanStepDTO(kind: "click", target: "the reply button", payload: nil),
      lastAction: ActionDTO(kind: "openApp", target: "Mail", payload: nil),
      screenBefore: "<AXButton> New mail\n<AXButton> Archive",
      screenNow: candidates.values.sorted().map { "<AXButton> \($0)" }.joined(separator: "\n"),
      recentHistory: ["openApp Mail"],
      candidates: candidates
    )
  }

  /// `String(format:)` with `%s` and a Swift String is a segfault, not a
  /// formatting bug — `%s` wants a C string. `%@` ignores width specifiers
  /// here, so padding is explicit instead.
  static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    if text.count >= width { return text + " " }
    let padding = String(repeating: " ", count: width - text.count)
    return right ? padding + text : text + padding
  }

  static func fmt(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
  }

  private static func fail(_ error: any Error) {
    FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
    exit(1)
  }
}
