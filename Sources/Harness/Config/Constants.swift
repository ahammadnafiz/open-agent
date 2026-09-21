import Foundation

/// Every threshold, ceiling, and tunable in the system.
///
/// **Nothing else in this codebase may contain a numeric threshold.** This file
/// and `docs/jev-questions.md` are the two surfaces a human reviews before a
/// release; a magic number anywhere else is invisible to that review.
///
/// Every value carries provenance: what it was measured against, or why it was
/// chosen. A constant without provenance is a guess someone will later mistake
/// for a finding.
///
/// All Jev thresholds were tuned against **`jev-1.13.0`**. Jev's own docs warn
/// that an alias moves when a release ships and the answers move with it, so the
/// version is pinned below and echoed on every response for verification.
public enum Constants {

  // MARK: - Models

  public enum Models {
    /// Pinned, never `jev-latest`. Every threshold here assumes this version.
    ///
    /// The only model id this project owns. Planning, vision and composition
    /// moved to the host agent in ADR 0009, which took `claude-sonnet-5`,
    /// `gemini-3.8-flash`, `claude-opus-5` and Apple Foundation Models with
    /// them. The measured A/B that chose the vision model is preserved in
    /// ADR 0004; it does not belong here now that nothing reads it.
    public static let jev = "jev-1.13.0"
  }

  // MARK: - Jev thresholds

  public enum Jev {

    // -- Verification -------------------------------------------------

    /// Below this, the last action did not move the task forward.
    ///
    /// Measured on the fixture set: true cases landed 0.95–0.98, false cases
    /// 0.03. The gap is enormous, so this sits in empty space rather than
    /// near any observed value — which is the point, given ±5pp drift.
    public static let progressed = 0.50

    /// The screen is effectively identical to before the action.
    /// Measured: 0.84 and 0.91 on genuine no-ops, 0.02–0.06 otherwise.
    public static let unchanged = 0.60

    /// An external obstacle blocks progress: login wall, permission prompt,
    /// CAPTCHA, paywall, error page.
    ///
    /// Measured 0.95 on a login wall while `progressed` was ambiguous at
    /// 0.54 — this question is what rescued that case. Never retried; a
    /// blocked task surfaces to the user immediately.
    public static let blocked = 0.70

    /// The whole task is visibly complete. Measured 0.95 on success, 0.03–0.14
    /// otherwise. Set high: a false positive here ends the task early and the
    /// user gets a half-finished result reported as success.
    public static let taskDone = 0.80

    /// Recent history is repeating with no screen change.
    /// Measured 0.95 when looping, 0.04–0.15 when not.
    public static let looping = 0.70

    /// The screen shows a *different* account, mailbox, document or
    /// repository than the one the task named.
    ///
    /// **UNMEASURED — this value is a placeholder.** It is the only
    /// threshold in this file without provenance, and it is written down
    /// rather than guessed silently. Needs the four fixtures in
    /// `jev-questions.md` §2.5 and a `battery-eval` run before it is
    /// trusted; if the answers straddle it, reword the question rather
    /// than move the number.
    ///
    /// Exists because the other five verification questions all answer
    /// *correctly* while the agent operates on the wrong instance — traced
    /// on a real task, and the failure is silent.
    ///
    /// Only asked when `task_context` is non-empty.
    public static let wrongContext = 0.70

    // -- Selection ----------------------------------------------------

    /// Minimum Choice confidence to act without seeing the screen.
    ///
    /// Jev's confidence is `(n·p_max − 1)/(n − 1)` — derived and confirmed
    /// live, 4/4 exact matches. It reads ONLY `p_max`, so it cannot see where
    /// the runner-up sits. That is why `selectionMargin` exists and why this
    /// value alone is never sufficient.
    ///
    /// VALIDATED 2026-09-18 on 16 intents across 4 real sites (tier 1, DOM):
    ///   this pair gated 11/16 steps through, and 11/11 were correct.
    ///   All 3 wrong answers fell below it (0.46/0.17, 0.38/0.22, 0.73/0.68).
    ///   2 correct answers were also gated out — an unnecessary 4.8s
    ///   escalation, which is the safe direction to be wrong in.
    public static let selectionConfidence = 0.80

    /// Minimum gap between the top two candidate probabilities.
    ///
    /// Two candidates at 0.48 and 0.47 produce an unremarkable `confidence`
    /// and are a coin flip. This catches that; `confidence` cannot.
    /// Carried its weight in the run above: 0.73/0.68 passed on margin alone
    /// and was still caught by the confidence floor.
    public static let selectionMargin = 0.25

    /// Below this, the element list is not enough and the step needs vision.
    ///
    /// A Choice's probabilities sum to 1, so something always wins even when
    /// the right target is absent. This unnormalised companion is the only
    /// way to detect "none of the above".
    public static let sufficient = 0.70

    // -- Risk (advisory only) -----------------------------------------

    /// Above this, ask the user before a *reversible* action.
    ///
    /// Measured with 7 atomic questions aggregated by `max` on 14 shell
    /// commands: 2/14 errors, versus 4/14 for a single holistic question.
    ///
    /// This gate NEVER decides irreversibility. That is deterministic —
    /// see `Safety` below and ADR 0001. A fork bomb scored 0.15 here, and a
    /// semantic reframing moved a destructive command from 0.98 to 0.42.
    public static let riskConfirm = 0.70

    // -- Mechanics ----------------------------------------------------

    /// Hard API ceiling. 256 returns
    /// `400 {"detail":"Too many choices. Must have at most 255 choices."}`
    public static let maxCandidates = 255

    /// Hard API ceiling. 11 returns
    /// `400 {"detail":"Too many score levels. Must have at most 10 levels."}`
    public static let maxScoreLevels = 10

    /// Action summaries carried in `recent_history`. Enough to detect a loop,
    /// short enough not to bloat the state — Jev's accuracy degrades as the
    /// state fills with content unrelated to the decision.
    public static let historyWindow = 4

    /// Measured: 383 ms warm from this machine, of which ~250 ms is network
    /// round trip. A step exceeding this is a network problem, not a model one.
    public static let requestTimeout: Duration = .seconds(10)

    // -- Transport ----------------------------------------------------
    //
    // There is no Swift SDK — Python and JS only — so the retry behaviour
    // the vendor SDKs provide has to be reproduced here. These mirror
    // `docs/typesafe.ai/sdk/python/api/retries` defaults exactly, so a
    // divergence in behaviour between this client and the reference
    // implementations is a bug in this file and nowhere else.

    /// `[D]` Vendor docs: `DEFAULT_BASE_URL = 'https://api.typesafe.ai'`.
    public static let baseURL = URL(string: "https://api.typesafe.ai")!

    /// `[D]` `$0.042` per million input tokens. **Output tokens are free**,
    /// which is why the batteries ask every question a branch might read.
    public static let inputPricePerMillionTokens = 0.042

    /// `[D]` Vendor SDK default `max_retries=2`.
    ///
    /// Retries are additionally clamped by the remaining step deadline — see
    /// `RetryPolicy`. Unclamped, 2 retries at a 10 s request timeout can
    /// reach 31.5 s inside a 20 s `Budget.stepTimeout`, and the step dies
    /// reporting a timeout instead of the rate limit that actually caused it.
    public static let maxRetries = 2

    /// `[D]` Vendor SDK defaults: `backoff_initial=0.5`, `backoff_max=5.0`,
    /// `backoff_jitter=0.25`.
    public static let backoffInitial: Duration = .milliseconds(500)
    public static let backoffMax: Duration = .seconds(5)
    public static let backoffJitter = 0.25

    /// `[D]` 64k tokens per request total; **32k for `state` plus the single
    /// longest question**. Checked locally before sending, so an oversized
    /// state fails naming its own cause instead of arriving as an opaque
    /// `422` whose message may not mention length.
    public static let stateTokenLimit = 32_000

    /// Characters per token, for the preflight estimate only.
    ///
    /// **MEASURED 2026-09-20, and the previous value was wrong in the dangerous
    /// direction.** It was 4 — the common English approximation — with a
    /// comment claiming that was conservative. It is not. `Probe jev-budget
    /// --browser` on a real GitHub page: 60 candidates, 4,320 bytes of state,
    /// **3,608 actual input tokens**. Four characters per token estimated
    /// 1,080, understating the real count by **3.34x**.
    ///
    /// Understating is the failure that matters: a state genuinely over the 32k
    /// ceiling would have been estimated at under 10k, sailed through the
    /// preflight, and failed at the API as a `422` whose message need not
    /// mention length — which is the exact failure the preflight exists to
    /// prevent.
    ///
    /// The state is JSON with short labels and heavy punctuation, and every
    /// candidate appears twice (once in `screen_now`, once in `candidates`), so
    /// it tokenises far worse than prose. Measured ratio is 1.197; this rounds
    /// down to 1 so the estimate errs high, which costs at worst one avoidable
    /// escalation.
    public static let charactersPerTokenEstimate = 1
  }

  // MARK: - Non-determinism

  /// Jev returns different values for byte-identical requests. Measured over
  /// 8 identical calls: **0.59 – 0.69**, a ±5pp swing, 7 of 8 runs unique.
  ///
  /// A threshold sitting inside that band flips between steps on unchanged
  /// input. These constants keep a decision stable once made.
  ///
  /// *Open Question Q3: both values are reasoned, not fitted. Tune against
  /// the eval fixture set before relying on them.*
  public enum Deadband {
    /// A probability must move by more than this to reverse a decision that
    /// has already been made for the current step index.
    public static let width = 0.08

    /// Steps a decision stays sticky before it may be re-evaluated.
    public static let stickySteps = 2
  }

  // MARK: - Safety

  public enum Safety {

    /// Whether an irreversible step stops and waits for a human.
    ///
    /// **Off, at the owner's request.** This is a decision, not an oversight,
    /// and it is worth writing down what it costs: page and message text
    /// reaches the planning model's context by construction, so an instruction
    /// embedded in something the agent *reads* can propose a send, a delete or
    /// a purchase. The sheet was the one thing in this design that such an
    /// instruction could not talk its way past, because a window is not
    /// expressible as an argument.
    ///
    /// It lives here rather than behind a flag on purpose: `CLI.approvalFlags`
    /// stays empty and `NoApprovalFlagTests` still holds. Nothing the agent
    /// reads at run time can turn this on or off — only a person editing this
    /// file and rebuilding. That is the part of the property worth keeping.
    ///
    /// `Irreversibility.classify` and `requiresConfirmation` are untouched, so
    /// every step is still classified and every verdict still logged. What
    /// changes is whether the agent stops, not whether it knows.
    public static let askBeforeIrreversible = false

    /// Kinds that are irreversible by definition. Mirrors
    /// `ActionKind.isIrreversibleByDefault` — the enum is the source of truth;
    /// this exists so the list is visible in the file humans review.
    public static let irreversibleKinds: Set<String> = [
      "publish", "send", "delete", "purchase",
    ]

    /// Element labels that force irreversible classification regardless of
    /// what the planner declared.
    ///
    /// This exists because **the verb never tells you what a click does**.
    /// Publishing a tweet is `click("Post")`, and `click` is reversible.
    /// Without this rule the entire confirmation boundary is bypassed by
    /// the ordinary mechanics of the task.
    ///
    /// Upgrade-only: matching forces `.irreversible`, never the reverse.
    /// False positives are accepted — a search form saying "Submit" asks once,
    /// which is the correct direction to be wrong in.
    ///
    /// English-only, and that is a known gap: a non-English UI falls back to
    /// the planner's declared intent alone, which is the weaker half.
    public static let labelDenylist = #"""
      (?ix)
      \b(
          post | tweet | publish | share |
          send | reply | submit | confirm |
          delete | remove | discard | destroy | erase | wipe |
          buy | purchase | pay | checkout | order | subscribe |
          deactivate | close\s+account | transfer | withdraw
      )\b
      """#

    /// Roles that imply form submission regardless of label.
    public static let submitRoles: Set<String> = ["submit", "menuitem-destructive"]

    /// Keys whose effect is routed through `labelDenylist` before executing.
    ///
    /// `enter` only. `tab` moves focus and activates nothing; `escape`
    /// dismisses, which is reversible by construction. `enter` is classified
    /// against the focused element's *submission target*, not the element
    /// itself — a To-field carries no hint that its form submits to `Send`.
    ///
    /// Reasoned, not measured. See ADR 0008, and Open Question Q8 for the
    /// uncovered case: a native text field whose window sends on `enter`
    /// with no label the denylist can reach.
    public static let gatedKeys: Set<String> = ["enter"]

    /// A `.captured` target that neither OCR, the tier 3b detector, nor the
    /// vision model could name is classified `.irreversible` unconditionally.
    ///
    /// This is the narrow form of "confirm every icon". Blanket confirmation
    /// was rejected as unusable — Chrome is 83% icon-only — but a target
    /// nothing in the system can describe cannot be denylisted at all, and
    /// acting on it unconfirmed is the one case with no mechanism behind it.
    ///
    /// Expected to fire rarely, because tier 4 labels what it selects. If it
    /// fires often, tier 4's label output is not working and that is the bug
    /// to fix — not this flag. Measure with `Probe run-task` before changing.
    public static let confirmUnnamedCaptured = true
  }

  // MARK: - Budgets

  /// Hard ceilings. Hitting any one stops the task cleanly, shows what was
  /// done, and asks the user. None of these is advisory.
  public enum Budget {
    /// Beyond this, the agent is not making progress it understands.
    public static let maxSteps = 40

    /// **Machine time only.** Time awaiting human confirmation is never
    /// charged — a task must not die because the user read carefully.
    public static let maxMachineTime: Duration = .seconds(90)

    /// Vision escalations per task. Each is ~2–4 s and ~$0.01. Three means
    /// the fast path is failing repeatedly and vision is not rescuing it.
    public static let maxEscalations = 3

    /// Full replans per task. Each discards the route and re-derives it.
    public static let maxReplans = 2

    /// Total spend. At measured rates a normal task costs ~$0.006–0.03, so
    /// this is roughly 10× a bad task and 100× a normal one.
    public static let maxDollars = 0.25

    /// Per-step wall clock before the step is abandoned and the ladder runs.
    public static let stepTimeout: Duration = .seconds(20)
  }

  // MARK: - Execution

  public enum Execution {
    /// How long a `wait` action pauses for.
    ///
    /// Charged to `Budget.maxMachineTime` like any other step, which is the
    /// reason it lives here rather than inline: a wait long enough to matter is
    /// a wait that competes with the task's own ceiling.
    public static let waitDuration: Duration = .milliseconds(300)

    /// How far one `scroll` action moves the page, in CSS pixels.
    ///
    /// `ActionKind.scroll` carries neither a distance nor a direction — the
    /// enum is closed and the payload is reserved for text — so the amount is
    /// a constant here rather than a number a planner could put in the audit
    /// log without anyone having approved it. About one default viewport,
    /// which is what "scroll down to see the rest" means to a person.
    public static let scrollDelta = 700

    /// How long to let the screen catch up after an action, before judging it.
    ///
    /// **An application is not finished when the call returns.** A click
    /// dispatches in microseconds; the redraw it causes happens on the app's
    /// own run loop. Reading the accessibility tree before that gives back the
    /// screen as it was — so Jev compares two identical descriptions, reports
    /// `unchanged`, and the ladder retries a step that had already worked.
    /// On a control that toggles, the retry undoes it.
    ///
    /// Measured on WhatsApp: clicking Search opened the panel on every run, and
    /// every run then read `unchanged ≈ 0.91` and retried.
    ///
    /// This *saves* time despite being a wait. A wasted retry costs a Jev call,
    /// an execution and another observation; polling stops the moment the
    /// screen differs, which is usually the first poll.
    /// Raised for single-page applications, which load and then render.
    /// Instagram answered `readyState: loading` with its navigation bar up and
    /// its content absent; a step judged there sees a page that is technically
    /// present and has nothing on it.
    public static let settleTimeout: Duration = .seconds(10)

    /// How often `settle` looks.
    ///
    /// **This used to be the unit stillness was measured in, and that made it
    /// two decisions wearing one number.** Eight stable polls at 150 ms meant
    /// "1.2 s of stillness" and "check six times a second" could not be
    /// changed independently, so looking more often silently weakened the
    /// guarantee. They are now separate: this is only the sampling rate, and
    /// `navigationQuiet` / `actionQuiet` own how long the screen must hold
    /// still. Sampling faster now costs nothing but a few cheap snapshots and
    /// buys back the quantisation — measured, a page that went still at
    /// t=1655 ms was not released until t=2869 ms, and 1214 ms of that was
    /// counting.
    public static let settlePollInterval: Duration = .milliseconds(60)

    /// How long the screen must hold still to count as settled, **after it
    /// has been seen to change.**
    ///
    /// Ten polls — 1.5s of stillness — was the price of not using the change
    /// itself as a signal. Waiting for the screen to move is far stronger
    /// evidence that the action landed than waiting for it to hold still, and
    /// once it has moved, a short quiet pause is long enough to trust.
    ///
    /// The whole wait cost about 4.7s of every 7s step. This is the number
    /// that made a five-step task take half a minute.
    public static let actionQuiet: Duration = .milliseconds(300)

    /// How much the DOM may grow between two polls and still count as still.
    ///
    /// **Stillness was defined as an exactly repeated node count, and a page
    /// that streams can never repeat one.** Settle fingerprinted the candidate
    /// list *and* `readiness()`, which is the DOM node count — so every feed
    /// appended a few nodes between polls, the fingerprint never matched
    /// twice, and the step burned the whole `actionSettleTimeout` even though
    /// the thing it was waiting for had landed in the first 200 ms. Measured
    /// on X: settle=1582 ms and settle=1662 ms against a 1500 ms cap.
    ///
    /// A ratio separates the two cases that matter, because they differ by
    /// orders of magnitude rather than by a little. A shell becoming a page is
    /// enormous — Instagram's inbox goes 157 nodes to roughly 3000, about 19x
    /// — and must still block. A feed appending one item to an already-built
    /// page is a couple of percent, and must not. Anything under a fifth of
    /// growth is treated as a page that has arrived and is merely alive.
    public static let settleGrowthFactor = 1.2

    /// How long a spinner on an otherwise finished document is believed.
    ///
    /// **A marker that never clears is scenery, not progress.** `readyState`
    /// is a fact; `aria-busy` and `role="progressbar"` are a page's opinion.
    ///
    /// X's composer is the case that made this expensive, and it is worth
    /// naming exactly. Its character counter — `data-testid="countdown-circle"`
    /// — carries `role="progressbar"`. Measured on x.com: an empty composer has
    /// one progressbar, `aria-hidden`, counting zero. One keystroke adds the
    /// ring and `busy` goes to 1. **Deleting the text again does not remove
    /// it.** So from the first character typed, the page claims to be loading
    /// for the rest of that composing session — and the step immediately after
    /// a type is the one that clicks Post. That step paid the full page-load
    /// budget and a settle that could never accumulate a single stable poll:
    /// ready=4041ms and settle=1662ms, about 5.7s of waiting on a 20x20px
    /// character counter.
    ///
    /// A genuine spinner on a complete document — a panel fetching its
    /// contents — resolves in well under this. So it is long enough to catch
    /// the real thing and short enough that the fake one costs little.
    public static let busyGrace: Duration = .milliseconds(600)

    /// The same, after a navigation.
    ///
    /// A page that has just been replaced gets the old benefit of the doubt.
    /// Instagram's inbox holds at 526 nodes and `readyState: complete` for a
    /// beat, then fills in its conversations — so a step judged after 450ms of
    /// quiet sees a navigation rail and calls it the page.
    /// The same, after a navigation.
    ///
    /// This is the single largest deliberate wait in the system and it is
    /// **not** quantisation, so it did not move. Measured on x.com, the page
    /// genuinely stopped changing at t=1655 ms and this number is why the step
    /// ran to t=2869 ms. Lowering it needs evidence about the case it was
    /// bought for — Instagram's inbox holding at 526 nodes with
    /// `readyState: complete` before its conversations arrive — not an
    /// argument about wanting the agent to be quicker.
    public static let navigationQuiet: Duration = .milliseconds(1_200)

    /// How long to let an ordinary action's effects land.
    ///
    /// **Separate from the navigation ceiling, and much shorter.** A live
    /// page never holds perfectly still — X's timeline ticks its timestamps,
    /// counts its replies and animates its spinners — so three identical
    /// observations is a condition it can simply never meet, and the wait ran
    /// to the full ten seconds after every click and every keystroke.
    /// Measured: settle=10055ms after a type, settle=10043ms after a click,
    /// against judge=544ms for the decision they were waiting for.
    ///
    /// The change is the evidence the action landed. Whether the page has
    /// finished arriving is `waitUntilReady`'s question, asked once, before
    /// the next judgement — so this does not need to answer it twice.
    public static let actionSettleTimeout: Duration = .milliseconds(1_500)

    /// How long to wait for a screen to finish arriving before judging it
    /// anyway.
    ///
    /// Shorter than the settle ceiling on purpose. Waiting for a page to load
    /// is worth a few seconds; a page that still says it is loading after four
    /// is a page that says that about itself permanently, and no amount of
    /// further waiting changes what is on it.
    public static let readyTimeout: Duration = .seconds(4)

    /// The same, in the middle of a task.
    ///
    /// A page that has already been navigated to and acted on is loaded; a
    /// spinner on it is a widget, not the site arriving. X shows one for
    /// seconds after a keystroke, and paying the full load budget for it put
    /// four seconds between typing a post and clicking Post.
    public static let readyTimeoutMidTask: Duration = .milliseconds(1_200)

    /// How long to wait for the screen to change at all before giving up on it.
    ///
    /// **A step that changed nothing is a real outcome, not a reason to
    /// wait.** Jev is what names it — `unchanged` is one of the five
    /// verification questions — and standing still for the full ceiling only
    /// delays that answer by ten seconds.
    public static let noChangeTimeout: Duration = .milliseconds(1_200)
  }

  // MARK: - Recovery

  public enum Recovery {
    /// Retries of the identical action before escalating. Clicks genuinely
    /// miss; more than one retry is just waiting for a different outcome from
    /// the same input.
    public static let retriesPerStep = 1
  }

  // MARK: - Browser

  public enum Browser {
    public static let bidiPort = 9333

    /// Where Zen keeps its profiles and its `profiles.ini`.
    public static let profilesRoot =
      NSString(string: "~/Library/Application Support/zen").expandingTildeInPath

    /// A dedicated, empty profile.
    ///
    /// Safest, and useless until each site is logged into by hand once
    /// (`Probe browser-login`). This was the original default, and the reason
    /// is still in `SPEC.md` § Boundaries: *never run the agent against a
    /// browser profile holding accounts the user did not explicitly assign to
    /// it.*
    public static let dedicatedProfilePath =
      NSString(string: "~/Library/Application Support/open-agent/zen-profile")
      .expandingTildeInPath

    /// Drive the browser the user actually uses, with every account they are
    /// logged into, rather than an empty profile.
    ///
    /// **This deliberately widens the boundary above — ADR 0011.** It is the
    /// default because a profile logged into nothing cannot do the tasks people
    /// actually ask for, and the one-time-login-per-site workaround is friction
    /// people abandon.
    ///
    /// Two constraints make this cost a browser restart, and neither has a way
    /// around it: `--remote-debugging-port` is a *startup* flag with no runtime
    /// equivalent, and a profile takes one process at a time.
    public static let useDefaultProfile = true

    /// How long to wait for a browser to release its profile lock after being
    /// asked to quit.
    public static let quitTimeout: Duration = .seconds(8)

    public static let zenBinary = "/Applications/Zen.app/Contents/MacOS/zen"

    /// `--no-remote` is REQUIRED. Without it Gecko hands the command to the
    /// already-running Zen, the new process exits silently, and the agent
    /// waits forever for a port that never opens.
    public static let launchArgs = ["--no-remote"]

    /// Cold start measured at 5–7 s. This is a connect-retry ceiling, not a
    /// sleep — a fixed sleep either wastes time or races.
    public static let launchTimeout: Duration = .seconds(20)

    public static let bundleIDs: Set<String> = [
      "app.zen-browser.zen",
      "com.google.Chrome",
    ]
  }

  // MARK: - Accessibility

  /// Pacing for synthesized keyboard input.
  ///
  /// **These are not cosmetic.** Keystrokes posted with no gap at all arrive
  /// faster than an application's event loop drains them, and the ones that do
  /// not fit are simply lost — a step that reports `dispatched=true` into a
  /// field that stays empty.
  public enum Typing {
    /// Gap between characters. Measured need, not a human-speed imitation:
    /// fast enough that a sentence is under a second, slow enough that each
    /// event is a separate trip through the app's run loop.
    public static let keystrokeIntervalMicroseconds: UInt32 = 12_000
    /// Gap between a key going down and coming back up. A zero-length press is
    /// not what any real keyboard produces, and some controls key off duration.
    public static let keyHoldMicroseconds: UInt32 = 8_000

    /// Gap between characters in the browser, in milliseconds.
    ///
    /// The accessibility tier's interval above is a mechanical need — one trip
    /// through the app's run loop per event. This one is not: `performActions`
    /// would deliver a whole sentence in a frame, and text that materialises at
    /// once reads as pasted by a machine rather than typed by someone. The
    /// person watching is the reason this number exists, so it is set where a
    /// sentence takes about a second.
    public static let webKeystrokeMilliseconds = 25

    /// How many characters share one pause.
    ///
    /// **A `pause` tick costs far more than the pause it asks for.** Measured
    /// against a live Firefox on a plain text input, typing the same 27
    /// characters three ways:
    ///
    ///   * 54 ticks, no pauses at all — 10–19 ms. Per-tick overhead is nil.
    ///   * 81 ticks, a 25 ms pause per character — 1800–2151 ms, for 675 ms
    ///     of pause actually asked for.
    ///   * 60 ticks, a 100 ms pause every fourth character — 1009–1028 ms,
    ///     for the same 700 ms asked.
    ///
    /// So the cost is not per tick, it is roughly `asked + 45 ms` per *pause*
    /// tick. Both shapes fit that model to within 5% (predicted 1890 ms and
    /// 1015 ms). Asking for the same total cadence in a quarter as many
    /// pauses therefore buys back about a second on a sentence, and what the
    /// person watches is unchanged in aggregate: the text still arrives over
    /// the same interval, in small bursts rather than one character at a time,
    /// which is what a hand on a keyboard actually produces.
    public static let webKeystrokeGroup = 4

    /// How long to wait for an application to accept focus.
    ///
    /// `AXUIElementSetAttributeValue(kAXFocused…)` returns immediately and the
    /// application acts on it later, on its own run loop. Posting keys in the
    /// same breath races that, and they land wherever focus still *is*.
    public static let focusTimeoutSeconds: Double = 0.6
    public static let focusPollMicroseconds: UInt32 = 20_000
  }

  public enum AX {
    /// Zen's menu tree alone is 10,804 nodes and takes 3.76 s to traverse.
    /// Without a deadline a pathological tree consumes the step budget by
    /// itself.
    public static let walkDeadline: Duration = .seconds(2)

    /// Node cap per walk, independent of the deadline.
    public static let maxNodes = 20_000

    /// `AXWindows` intermittently returns an empty array for windows that
    /// demonstrably exist. Measured: Notes and Cursor returned 0 after 8
    /// retries over 3.2 s; Zen and Finder returned on the first try.
    /// A single read is not a valid observation.
    public static let windowRetries = 8
    public static let windowRetryDelay: Duration = .milliseconds(400)

    /// Characters of a control's `AXValue` kept for the Jev `state`.
    ///
    /// A text area's value is its entire contents, so uncapped this would let
    /// one focused editor become the whole state. 120 matches the slice the
    /// DOM snapshot already applies in `SnapshotScript`, so both tiers spend
    /// the same on the same thing.
    public static let valueLength = 120

    /// Electron's `AXManualAccessibility` unlock is debounced at a hard-coded
    /// 2 s in `electron_application.mm`, and every toggle restarts it.
    public static let electronUnlockDelay: Duration = .seconds(3)

    /// How long to wait for an app the plan asked to open to draw a window.
    ///
    /// `/usr/bin/open` returns once the app is *launched*, not once it has
    /// drawn anything. A cold start of a large app is seconds; a warm one is
    /// instant. Polling spans both, where a fixed sleep would either stall
    /// every warm launch or fail every cold one.
    /// Seconds and microseconds are the source values because the two callers
    /// need different shapes: the executable waits across `await`, and the
    /// executor waits synchronously because an `AXUIElement` must not cross a
    /// suspension point.
    public static let launchTimeoutSeconds: Double = 20
    public static let launchPollMicroseconds: UInt32 = 250_000
    public static var launchTimeout: Duration { .seconds(launchTimeoutSeconds) }
    public static var launchPollInterval: Duration { .microseconds(launchPollMicroseconds) }
  }

  // MARK: - Screen capture and OCR (tier 3)

  public enum OCR {
    /// `.accurate`, never `.fast`. Measured on identical real pages, `.fast`
    /// produced `Cr8ate`, `R&ad`, `Mlcrosoft`, `Hirln`; `.accurate` produced
    /// none of them. 368 ms against 92 ms — the budget absorbs it.
    public static let useAccurateRecognition = true

    /// MUST be 0. `RecognizeTextRequest` defaults this to 0.03125 (1/32 of
    /// image height), which returns ZERO observations on a Retina screenshot
    /// in `.fast` mode. Measured sweep at 2880×1800, UI text ≈ 0.0144:
    ///   0.0 → 86 obs · 0.010 → 81 · 0.0144 → 1 · 0.03125 (default) → 0
    /// Apple's ObjC header claims the default is 0.0. The Swift struct
    /// measurably disagrees. Silent total failure, not an error.
    public static let minimumTextHeightFraction = 0.0

    /// "Corrects" filenames and truncated UI labels into prose. Off.
    public static let usesLanguageCorrection = false

    /// Capture at native Retina scale and never downscale. At 1× recall of
    /// known UI labels was 21/34 and missed the entire menu bar; at 2×, 34/34.
    public static let downscale = false

    /// DO NOT ADD A GAP-SPLITTING THRESHOLD HERE. It was implemented and
    /// measured on 2026-09-18, and no value works.
    ///
    /// Vision returns LINE observations, so adjacent controls merge into one
    /// box — `"Donate Create account Log in"` is three separate links. The
    /// per-word boxes from `boundingBox(for:)` are real glyph metrics
    /// (`iiii` = 77 px vs `WWWW` = 257 px), but the gaps carry no signal:
    ///
    ///   DPR 1   between links 2 px   within a link 2 px
    ///   DPR 2                 3 px                 3 px
    ///   DPR 3                 6 px                 5 px
    ///
    /// Pages render navigation at word spacing and resolution scales both
    /// gaps equally. Control boundaries must come from the detector, not
    /// from text geometry. See build-sequence.md task 3.4b.
    ///
    /// UNTIL 3.4b EXISTS, TIER 3 IS NOT A SELECTION TIER — its output feeds
    /// tier 4's numbered marks and is never selected from directly.
    public static let tier3FeedsMarksOnly = true

    /// Backing-scale factor used when `downscale` is false.
    ///
    /// Measured, not assumed: at 1x, recall of known UI labels was 21/34 and
    /// missed the entire menu bar; at 2x it was 34/34. This is the number that
    /// measurement produced, so it belongs in the file that records provenance.
    public static let retinaScale = 2

    /// Characters of the SHA-256 frame hash kept in the step log.
    ///
    /// The hash exists so a `.captured` bbox can be tied back to the frame it
    /// was measured in — ADR 0007 — and 16 hex characters is 64 bits, which is
    /// collision-free for the handful of frames one task produces while staying
    /// short enough to read in a log.
    public static let frameHashLength = 16

    /// Transient `-3811` SCStreamError occurs even on windows that just
    /// captured successfully.
    public static let captureRetries = 3
    public static let captureRetryDelay: Duration = .milliseconds(250)
  }

  // MARK: - UI

  public enum HUD {
    public static let size = CGSize(width: 380, height: 120)
    public static let confirmSize = CGSize(width: 380, height: 300)

    /// Never auto-dismiss or auto-approve a confirmation. It is the only
    /// safety boundary in the system; a timeout that defaults to "yes" is a
    /// hole, and one that defaults to "no" is a task that dies while the
    /// user is reading.
    public static let confirmationTimeout: Duration? = nil

    // -- Cursor overlay -----------------------------------------------
    //
    // The agent drives other people's applications, so without a drawn
    // cursor the only evidence anything is happening is windows changing by
    // themselves. These values buy legibility with wall-clock time, and
    // that time is charged to `Budget.maxMachineTime` like any other.
    //
    // Styling — corner radii, blur, colour — deliberately does NOT live
    // here. This file is what a human reviews before a release, and padding
    // it with cosmetics hides the values that decide behaviour.

    /// Master switch. Off costs ~400 ms less per step and makes the agent
    /// invisible while it works. On is the default because an agent nobody
    /// can watch is an agent nobody can interrupt.
    public static let motionEnabled = true

    /// Pointer speed.
    ///
    /// **This is narration, and it was sitting on the critical path.**
    /// Measured on a real X step: `act=1011ms`, of which roughly 690 ms was
    /// the cursor flying to a target the executor could have been told about
    /// immediately. Three targeted steps in a task, and the animation alone
    /// cost more than every Jev call in the run put together.
    ///
    /// The previous value was argued from Fitts's law — a *hand* reaching for
    /// a target averages near 1,100 px/s. That is the right model for
    /// predicting a human and the wrong one for drawing an agent: nothing here
    /// is reaching, and the user is watching a report of a decision that has
    /// already been made. What the motion has to do is carry direction, and
    /// direction survives being fast.
    ///
    /// The anticipation ring is untouched, because that is the part that
    /// actually informs — see `anticipationSeconds`.
    public static let pixelsPerSecond: Double = 3_200

    /// Floor and ceiling on travel time, so a short hop still reads as
    /// movement and a corner-to-corner sweep does not stall the step.
    ///
    /// The ceiling is what a full-screen sweep costs, and it was being paid on
    /// most steps: 0.7 s of every targeted step, every time.
    public static let minMoveSeconds: Double = 0.10
    public static let maxMoveSeconds: Double = 0.30

    /// How long the target ring is visible before the cursor sets off.
    ///
    /// This is the anticipation window — the user sees WHERE before WHAT.
    /// It is the overlay's entire safety contribution and the reason it is
    /// not purely decorative, so it is the last value that should be cut
    /// for speed.
    public static let anticipationSeconds: Double = 0.14

    /// Press-and-release, then a beat before the ring clears.
    ///
    /// These run *alongside* the executor rather than in front of it, so they
    /// only cost wall-clock time when the dispatch is faster than the
    /// animation — which, for a click, it always is.
    public static let pressSeconds: Double = 0.07
    public static let settleSeconds: Double = 0.05

    /// Worst case added per targeted step: anticipation + maxMove + press +
    /// settle = 0.56 s, from 0.99 s. Typical is now ~0.35 s. Over a 10-step
    /// task that is 3.5 s against a 90 s ceiling.
    public static let worstCaseOverheadSeconds: Double =
      anticipationSeconds + maxMoveSeconds + pressSeconds + settleSeconds
  }
}
