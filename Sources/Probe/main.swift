import CoreGraphics
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
case "bidi-dom":
  await Probe.bidiDOM(
    url: arguments.count > 2 ? arguments[2] : "https://en.wikipedia.org/wiki/Accessibility")
case "bidi-ax":
  await Probe.bidiAX(url: arguments.count > 2 ? arguments[2] : nil)
case "tabs": await Probe.tabs(url: arguments.count > 2 ? arguments[2] : nil)
case "browser-login": Probe.browserLogin()
case "battery-eval": await Probe.batteryEval()
case "capture-fixtures": await Probe.captureFixtures()
case "captured-eval":
  await Probe.capturedEval(
    apps: arguments.count > 2 ? Array(arguments[2...]) : ["Ghostty", "Zen", "Finder"])
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
      swift run Probe bidi-dom [url]       what tier 1 sees, in one browser call
      swift run Probe browser-login        log the agent profile into a site, once
      swift run Probe windows              what the window server reports

      swift run Probe battery-eval         every question x 5 repeats, straddle gate
      swift run Probe capture-fixtures     record real DOM + AX element lists

      swift run Probe captured-eval [apps] what tier 3 sees where tier 2 sees nothing
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
      // `--browser` measures a real page, which is the case that matters: a
      // native window offers tens of controls, a web page offers hundreds, and
      // the 32k state ceiling is only ever in danger on the second.
      let candidates: CandidateSet
      if app == "--browser" || app == "browser" {
        let handle = try await BrowserLauncher.ensureDrivable(allowRestart: true)
        let bidi = BiDiClient(port: handle.port)
        try await bidi.connect()
        let source = BiDiSource(client: bidi)
        candidates = try CandidateFilter.reduce(try await source.observe())
        await bidi.close()
      } else {
        let source = try AXSource(appName: app)
        candidates = try CandidateFilter.reduce(try await source.observe())
      }
      let context = sampleContext(candidates: candidates.criteria)

      let estimated =
        (try? JSONEncoder().encode(context).count).map {
          $0 / Constants.Jev.charactersPerTokenEstimate
        } ?? 0

      let verdict = try await client.step(context)
      print("source             \(app)")
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

  // MARK: - battery-eval

  /// SPEC.md § S8 — *"Every battery question, over 5 repeats on its fixture
  /// set, stays on one side of its threshold."*
  ///
  /// **A single pass proves nothing.** Jev is non-deterministic: measured over
  /// 8 identical requests, the same input returned 0.59–0.69, and 7 of 8 runs
  /// were unique. So the metric that gates a merge is not mean accuracy — it is
  /// whether any question's answers **straddle** its threshold across repeats.
  ///
  /// A question that straddles fails even at 100% mean accuracy, because a
  /// threshold sitting where the answers live is a coin flip wearing a number.
  /// The fix is never to nudge the threshold until the suite passes: reword the
  /// question, or move the threshold away from the crowded region.
  static func batteryEval(repeats: Int = 5) async {
    guard let client = makeClient() else { return }

    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Tests/Fixtures/jev")
    let fixtures: [BatteryFixture]
    do {
      fixtures = try BatteryFixture.load(from: directory)
    } catch {
      FileHandle.standardError.write(
        Data("could not load fixtures from \(directory.path): \(error)\n".utf8))
      exit(1)
    }
    guard !fixtures.isEmpty else {
      FileHandle.standardError.write(Data("no fixtures in \(directory.path)\n".utf8))
      exit(1)
    }

    print("\(fixtures.count) fixtures x \(repeats) repeats")
    print("")

    // "question/side" -> every observed value for fixtures asserting that side.
    //
    // **Grouped by side, because a question with fixtures on both sides has a
    // bimodal distribution and an aggregate mean over it describes nothing.**
    // `risk_destructive` averaged 0.45 across a fixture that should score near
    // 0 and one that should score near 1; that number is not about either of
    // them. Worse, the straddle test was switched off entirely whenever a
    // question had both sides — so the better the fixture coverage, the less
    // the gate checked.
    var byGroup: [String: [Double]] = [:]
    // question -> every observed value, and whether each landed correctly
    var values: [String: [Double]] = [:]
    var errors: [String: Int] = [:]
    var counts: [String: Int] = [:]
    var targetHits = 0
    var targetTotal = 0
    var cost = 0.0
    var wrongCases: [String: [String]] = [:]

    for fixture in fixtures {
      for repeatIndex in 1...repeats {
        let verdict: StepVerdict
        do {
          verdict = try await client.step(fixture.state.context)
        } catch {
          print("  \(fixture.name) repeat \(repeatIndex): FAILED \(error)")
          continue
        }
        cost += verdict.usage.dollars

        let observed: [String: Double?] = [
          Batteries.ID.progressed: verdict.progressed,
          Batteries.ID.unchanged: verdict.unchanged,
          Batteries.ID.blocked: verdict.blocked,
          Batteries.ID.taskDone: verdict.taskDone,
          Batteries.ID.looping: verdict.looping,
          Batteries.ID.wrongContext: verdict.wrongContext,
          Batteries.ID.sufficient: verdict.sufficient,
          Batteries.ID.riskDestructive: verdict.riskDestructive,
          Batteries.ID.riskOutbound: verdict.riskOutbound,
          Batteries.ID.riskCredential: verdict.riskCredential,
        ]

        for (question, side) in fixture.expect {
          guard let value = observed[question] ?? nil,
            let threshold = BatteryFixture.threshold(for: question)
          else { continue }
          values[question, default: []].append(value)
          byGroup["\(question)/\(side.rawValue)", default: []].append(value)
          counts[question, default: 0] += 1
          let correct = side == .above ? value >= threshold : value < threshold
          if !correct {
            errors[question, default: 0] += 1
            // Naming the fixture is the difference between "this question is
            // wrong half the time" and knowing which half.
            wrongCases[question, default: []].append(
              "\(fixture.name) wanted \(side == .above ? "≥" : "<") \(fmt(threshold, 2)), "
                + "got \(fmt(value, 3))")
          }
        }

        // The ambiguous fixtures assert nothing but still contribute variance,
        // which is the only reason they exist.
        if fixture.expect.isEmpty, let wrongContext = verdict.wrongContext {
          values[Batteries.ID.wrongContext, default: []].append(wrongContext)
        }

        if let expected = fixture.state.expectedTarget {
          targetTotal += 1
          if verdict.target?.choice == expected { targetHits += 1 }
        }
      }
    }

    print("question / side       n    err      mean    sd       straddles?")
    print("────────────────────  ───  ───────  ──────  ───────  ──────────")

    var straddling: [String] = []
    for group in byGroup.keys.sorted() {
      let observations = byGroup[group] ?? []
      guard !observations.isEmpty else { continue }
      let question = String(group.split(separator: "/")[0])
      let mean = observations.reduce(0, +) / Double(observations.count)
      let variance =
        observations.reduce(0) { $0 + pow($1 - mean, 2) } / Double(observations.count)
      let sd = variance.squareRoot()

      // The gate, asked of one side at a time. Every observation in this group
      // is expected on the same side of the line, so any disagreement between
      // repeats is the question failing to separate a case from itself — which
      // is what a straddle is, and it is invisible in an aggregate.
      let threshold = BatteryFixture.threshold(for: question) ?? 0
      let anyAbove = observations.contains { $0 >= threshold }
      let anyBelow = observations.contains { $0 < threshold }
      let straddles = anyAbove && anyBelow
      if straddles { straddling.append(group) }

      let err = observations.filter { value in
        group.hasSuffix("/above") ? value < threshold : value >= threshold
      }.count

      print(
        pad(group, 22) + pad("\(observations.count)", 5)
          + pad("\(err)/\(observations.count)", 9) + pad(fmt(mean, 3), 8)
          + pad(fmt(sd, 4), 9) + (straddles ? "STRADDLES" : "no")
      )
    }

    if targetTotal > 0 {
      print("")
      print("target selection  \(targetHits)/\(targetTotal) correct")
    }
    print("")
    print("cost              $\(fmt(cost, 4))")

    // **A question that is simply wrong must fail this, and it did not.**
    // PASS/FAIL used to depend only on straddling, so the `err` column was
    // printed and then ignored — `risk_destructive` answered 5 of its 10
    // fixtures wrongly and the gate still said PASS. A gate that reports a
    // number it does not act on is decoration.
    //
    // Straddling and being wrong are different faults with different repairs,
    // so they are reported separately: a straddle means the question cannot
    // separate its cases, and an error means it separates them the wrong way.
    let wrong = wrongCases.keys.sorted()

    if straddling.isEmpty, wrong.isEmpty {
      print("\nPASS — every question separates its cases, on the correct side")
      return
    }

    if !wrong.isEmpty {
      print("\nFAIL — wrong answers:")
      for question in wrong {
        let cases = wrongCases[question] ?? []
        print("  \(question): \(cases.count)/\(counts[question] ?? 0)")
        for detail in Set(cases).sorted() { print("      \(detail)") }
      }
      print("Reword the question so it separates these cases. Moving the")
      print("threshold to cover them makes the gate agree with a wrong answer.")
    }
    if !straddling.isEmpty {
      print("\nFAIL — straddling: \(straddling.joined(separator: ", "))")
      print("Reword the question, or move the threshold away from the crowded")
      print("region. Never nudge the threshold to make this pass.")
    }
    exit(1)
  }

  // MARK: - bidi-ax

  /// Does BiDi give us what CDP's `Accessibility.getFullAXTree` gives
  /// browser-harness?
  ///
  /// Measured on Instagram in Chrome: a DOM selector whitelist finds 24
  /// actionable elements on a page where the accessibility tree finds 76. The
  /// whitelist is what `SnapshotScript` uses, and it is why the agent reported
  /// `a=11 btn=0` on an inbox full of controls.
  ///
  /// CDP is not available on a Gecko browser, so the question is whether
  /// `browsingContext.locateNodes` with an accessibility locator reaches the
  /// same computed roles. If it does, the fix keeps the user's own browser.
  static func bidiAX(url: String?) async {
    let handle: BrowserLauncher.Handle
    do {
      handle = try await BrowserLauncher.ensureDrivable(allowRestart: true)
    } catch {
      print("probe failed: \(error)")
      return
    }
    let client = BiDiClient(port: handle.port)
    do {
      try await client.connect()
      if let url { try await client.navigate(to: url) }

      let roles = [
        "button", "link", "textbox", "searchbox", "combobox", "checkbox",
        "tab", "menuitem", "switch", "option", "listbox", "radio",
      ]
      print("role         nodes")
      print("───────────  ─────")
      var total = 0
      for role in roles {
        do {
          let found = try await client.locateByRole(role)
          total += found
          print(pad(role, 13) + "\(found)")
        } catch {
          print(pad(role, 13) + "unsupported: \(error)")
        }
      }
      print("")
      print("total        \(total)")
      print("")
      print("one button node, raw:")
      print((try? await client.locateRaw("button")) ?? "none")
    } catch {
      print("probe failed: \(error)")
    }
    await client.close()
  }

  // MARK: - capture-fixtures

  /// Records real element lists so SPEC.md § S7 can be asserted offline.
  ///
  /// S7 is *"Across every captured DOM and AX fixture, the filtered candidate
  /// set is ≤255"* — **captured**, not synthesised. A test that builds 300
  /// identical in-memory elements proves the comparison operator works; it says
  /// nothing about whether real pages stay under the ceiling, which is the
  /// claim. Link-dense pages are the interesting case, so they are what this
  /// records.
  static func captureFixtures() async {
    let pages = [
      ("wikipedia-accessibility", "https://en.wikipedia.org/wiki/Accessibility"),
      ("hacker-news", "https://news.ycombinator.com"),
      ("github-repo", "https://github.com/browser-use/jev-ultrafast"),
    ]
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Tests/Fixtures")

    do {
      let handle = try await BrowserLauncher.ensureDrivable(allowRestart: true)
      let client = BiDiClient(port: handle.port)
      try await client.connect()
      let source = BiDiSource(client: client)

      for (name, url) in pages {
        try await client.navigate(to: url)
        // Real pages settle after `complete`; a snapshot taken on the first
        // frame records a page nobody ever saw.
        try await Task.sleep(for: .seconds(1))
        let elements = try await source.observe()
        try write(elements, to: root.appending(path: "dom/\(name).json"))
        print("  dom/\(name).json  \(elements.count) elements")
      }
      await client.close()
    } catch {
      print("  browser capture skipped: \(error)")
    }

    for app in ["Zen", "Finder", "Ghostty"] {
      do {
        let source = try AXSource(appName: app)
        let elements = try await source.observe()
        try write(elements, to: root.appending(path: "ax/\(app.lowercased()).json"))
        print("  ax/\(app.lowercased()).json  \(elements.count) elements")
      } catch {
        print("  ax/\(app.lowercased()) skipped: \(error)")
      }
    }
  }

  /// Writes an element list, scrubbed.
  ///
  /// `SPEC.md` § Boundaries: never commit *"a captured screenshot, or a DOM
  /// fixture containing session tokens."* A URL is the usual carrier, so query
  /// strings and fragments come off before anything is written.
  private static func write(_ elements: [Element], to url: URL) throws {
    let scrubbed = elements.map { element -> Element in
      Element(
        ref: element.ref, role: element.role, label: scrub(element.label),
        enabled: element.enabled, inViewport: element.inViewport,
        bounds: element.bounds, visionLabel: element.visionLabel.map(scrub)
      )
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(scrubbed).write(to: url, options: .atomic)
  }

  private static func scrub(_ text: String) -> String {
    guard let range = text.range(of: "?") ?? text.range(of: "#") else { return text }
    return String(text[text.startIndex..<range.lowerBound])
  }

  // MARK: - captured-eval

  /// Open Question Q7 — *"the captured tier is entirely unmeasured, and it is
  /// the largest unknown in the system."*
  ///
  /// **What this measures:** what tier 3 yields on real surfaces, and
  /// specifically what it yields where tier 2 yields nothing. Ghostty is the
  /// documented floor — 12 AX nodes, zero pressable, with a live focused
  /// on-screen window — so it is the case that decides whether tiers 3–4 are
  /// worth having at all.
  ///
  /// **What this cannot measure, stated rather than implied.** Q7 asks three
  /// things and a probe can only answer one of them:
  ///
  ///   1. end-to-end hit rate of a captured click — needs a ground-truth
  ///      target per surface, which is hand-labelling, not automation;
  ///   2. how often tier 4 returns a label the denylist can use — tier 4 *is*
  ///      the host agent answering a `needs_eyes` callback, so there is no
  ///      model here to ask;
  ///   3. how often `confirmUnnamedCaptured` fires — by construction it cannot
  ///      fire on `.ocrLine`, which always carries text. It is reachable only
  ///      from `.detectorBox` (tier 3b, not built) and `.visionMark` (tier 4).
  ///
  /// So this closes the first and largest piece and leaves the rest open,
  /// honestly, rather than reporting a number that looks like an answer.
  static func capturedEval(apps: [String]) async {
    guard CGPreflightScreenCaptureAccess() else {
      print("Screen Recording is not granted to this binary.")
      print("System Settings > Privacy & Security > Screen Recording")
      print("The grant is per-binary, so a rebuilt executable needs it again.")
      exit(2)
    }

    print("app          tier2  tier3  capture  ocr    merged-line examples")
    print("───────────  ─────  ─────  ───────  ─────  ─────────────────────")

    for app in apps {
      var tier2 = "-"
      do {
        let source = try AXSource(appName: app)
        let candidates = try CandidateFilter.reduce(try await source.observe())
        tier2 = "\(candidates.count)"
      } catch {
        tier2 = "0"
      }

      do {
        let reading = try await OCRSource(appName: app).read()
        // A line carrying several words separated by wide gaps is the merged
        // case ADR 0005 measured as unsplittable. Counting them is the closest
        // thing to a merge rate available without ground truth.
        let multiWord = reading.elements.filter {
          $0.label.split(separator: " ").count >= 3
        }
        let example = multiWord.first?.label.prefix(34) ?? ""
        print(
          pad(app, 13) + pad(tier2, 7) + pad("\(reading.elements.count)", 7)
            + pad("\(reading.captureMilliseconds)ms", 9)
            + pad("\(reading.recognizeMilliseconds)ms", 7)
            + (example.isEmpty ? "-" : "\"\(example)…\"")
        )
      } catch {
        print(pad(app, 13) + pad(tier2, 7) + "skipped: \(error)")
      }
    }

    print("")
    print("tier2 = labelled+actionable AX elements after the filter")
    print("tier3 = Vision text LINE observations — not controls. Adjacent")
    print("        controls merge into one box, and splitting by gap was")
    print("        measured impossible (2/2 px at DPR 1, 6/5 px at DPR 3).")
    print("        That is why tier3FeedsMarksOnly is true and why every")
    print("        .ocrLine ref is refused by CapturedExecutor.")
    print("")
    print("Still open in Q7: captured-click hit rate, tier 4 label quality, and")
    print("confirmUnnamedCaptured frequency. All three need either hand-labelled")
    print("ground truth or a host model in the loop.")
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

  // MARK: - bidi-dom

  /// What tier 1 actually sees, and how long one atomic snapshot takes.
  ///
  /// ADR 0010's whole claim is that reading the page in **one** browser call is
  /// what makes a DOM agent fast — `browser-use/jev-ultrafast` measured protocol
  /// calls dropping from 1,092 to 101 on the same task. This prints the one call.
  /// Which tabs exist, and what the agent sees when it picks one.
  static func tabs(url: String?) async {
    let client = BiDiClient()
    do {
      _ = try await BrowserLauncher.ensureDrivable(allowRestart: true)
      try await client.connect()
      print("  who    container    url")
      for row in try await client.inventory(cookiesFor: url) { print(row) }
      print("\n▸ is the tab on screen — a new tab is opened from there, so it")
      print("  lands in the same container, which is the same cookie jar.")
      await client.close()
    } catch {
      print("failed: \(error)")
      await client.close()
    }
  }

  static func bidiDOM(url: String) async {
    let client = BiDiClient()
    do {
      let connectStarted = ContinuousClock.now
      let handle = try await BrowserLauncher.ensureDrivable(allowRestart: true)
      if handle.restartedExistingBrowser {
        print("restarted your browser so its profile could be driven; tabs are restored")
      }
      try await client.connect()
      let connectMs = (ContinuousClock.now - connectStarted).inSeconds * 1000
      print("profile              \(handle.profile)")

      try await client.navigate(to: url)

      // Diagnostic: what does the page think its own geometry is? A window the
      // compositor has not sized yet reports innerHeight 0, and every element
      // then fails the viewport test.
      let probeData = try await client.evaluate(
        """
        ({ w: window.innerWidth, h: window.innerHeight,
           anchors: document.querySelectorAll('a[href]').length,
           ready: document.readyState, title: document.title })
        """
      )
      if let d = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any] {
        print("viewport             \(d["w"] ?? "?") x \(d["h"] ?? "?")")
        print("a[href] in document  \(d["anchors"] ?? "?")")
        print("readyState           \(d["ready"] ?? "?")")
      }

      let source = BiDiSource(client: client)
      let snapshotStarted = ContinuousClock.now
      let elements = try await source.observe()
      let snapshotMs = (ContinuousClock.now - snapshotStarted).inSeconds * 1000
      let candidates = try CandidateFilter.reduce(elements)

      print("")
      print("url                  \(url)")
      print("connect              \(fmt(connectMs, 0)) ms")
      print("snapshot             \(fmt(snapshotMs, 0)) ms   (one script.evaluate)")
      print("actions              \(elements.count)")
      print("survived the filter  \(candidates.count)")
      print("")
      for (index, element) in candidates.elements.prefix(30).enumerated() {
        let submit = element.submitLabel.map { " ->\($0)" } ?? ""
        print(
          "  \(pad("e\(index)", 6))\(pad(element.role, 12))\(element.label.prefix(60))\(submit)")
      }
      if candidates.count > 30 { print("  … \(candidates.count - 30) more") }

      await client.close()
    } catch {
      await client.close()
      fail(error)
    }
  }

  /// The one-time setup per site. The agent profile starts logged into nothing,
  /// so the first task touching a new site returns `blocked` and stops — correct
  /// behaviour that looks like a bug the first time.
  static func browserLogin() {
    do {
      print("opening the profile at \(BrowserProfile.active())")
      print("log in by hand, complete any 2FA, then quit the browser.")
      try BrowserLauncher.loginSession()
      print("done — the session cookie now lives in the agent's profile")
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
