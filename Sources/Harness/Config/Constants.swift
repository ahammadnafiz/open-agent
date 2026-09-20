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
        public static let jev = "jev-1.13.0"

        /// OpenRouter IDs. Configuration, not truth — the catalogue moves.
        public static var planner = "anthropic/claude-sonnet-5"      // $2.00/M

        /// Vision escalation. Chosen by measurement, not reputation — see ADR 0004.
        ///
        /// Measured on 12 intents over one screenshot with 23 numbered boxes:
        ///   gemini-3.8-flash      icons 5/7 (71%)  text 5/5  total 83%  $0.00096
        ///   gemini-3.5-flash-lite icons 4/7 (57%)  text 5/5  total 75%  $0.00039
        ///   gemini-2.5-pro        icons 5/7 (71%)  text 5/5  total 83%  $0.00443
        ///   claude-sonnet-5       icons 5/7 (71%)  text 5/5  total 83%  $0.00989
        ///
        /// flash-lite is the only one below the ceiling, and the gap is entirely on
        /// icon targets — which is the only class tier 4 ever sees, since tiers 1–3
        /// already resolve anything text-labelled.
        public static var vision = "google/gemini-3.8-flash"          // $0.75/M

        /// Used only when a replan has already failed once at the default tier.
        public static var replanEscalated = "anthropic/claude-opus-5"
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

        /// The debug port can only be enabled at process start, so the agent
        /// cannot attach to a browser the user opened. It owns this profile;
        /// the user's daily profile is never touched, never quit, never exposed.
        public static var agentProfilePath =
            NSString(string: "~/Library/Application Support/computer-agent/zen-profile")
                .expandingTildeInPath

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

        /// Electron's `AXManualAccessibility` unlock is debounced at a hard-coded
        /// 2 s in `electron_application.mm`, and every toggle restarts it.
        public static let electronUnlockDelay: Duration = .seconds(3)
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

        /// Transient `-3811` SCStreamError occurs even on windows that just
        /// captured successfully.
        public static let captureRetries = 3
        public static let captureRetryDelay: Duration = .milliseconds(250)
    }

    // MARK: - On-device composition

    public enum OnDevice {
        /// Apple Foundation Models is a hard 4,096 tokens TOTAL. A verbose
        /// instruction string plus a nested @Generable schema overflowed it at
        /// 4,090 tokens before any input arrived. Keep instructions short.
        public static let maxInstructionChars = 400

        /// Measured 1.33 s for a short post. Beyond this, fall back.
        public static let timeout: Duration = .seconds(8)
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
    }
}
