import Foundation

/// The question batteries, transcribed verbatim from `docs/jev-questions.md`.
///
/// **Changing a word here is a behavioural change, not a copy edit.** Jev's
/// answers depend on exact wording; the one measured miss in the whole battery
/// came from asking *"did the action succeed"* instead of asking about progress,
/// and it scored 0.54 — dead on its threshold — while being literally correct.
/// Re-run `Probe battery-eval` after any change and commit the new numbers.
///
/// Three rules govern every question below, from `docs/jev-questions.md` §7:
///   1. `true` always means **more caution or more progress**. Never invert.
///   2. Name the narrowest fact that decides the branch.
///   3. Reference state fields by name in backticks, so one batch serves them all.
public enum Batteries {

  /// Stable question ids. The key is never sent to the model — the vendor
  /// documents that question keys are not used in inference — so these are
  /// purely how code finds an answer again.
  public enum ID {
    public static let progressed = "progressed"
    public static let unchanged = "unchanged"
    public static let blocked = "blocked"
    public static let taskDone = "task_done"
    public static let looping = "looping"
    public static let wrongContext = "wrong_context"
    public static let target = "target"
    public static let sufficient = "sufficient"
    public static let riskDestructive = "risk_destructive"
    public static let riskOutbound = "risk_outbound"
    public static let riskCredential = "risk_credential"
  }

  /// The full per-step batch.
  ///
  /// One request carries verification, selection and intent risk together,
  /// because a batched question is free in wall-clock and near-free in money.
  /// A design that verifies in a separate call pays twice for nothing.
  ///
  /// - Parameter candidates: `id → label`. Omitted entirely when empty, so the
  ///   batch never sends a Choice with no options.
  /// - Parameter includeWrongContext: only when `task_context` is non-empty.
  public static func step(
    candidates: [String: String],
    includeWrongContext: Bool
  ) -> [String: Question] {
    var q: [String: Question] = [
      // -- Verification: five nouls, each naming one narrow fact --------

      ID.progressed: .noul(
        instructions:
          "Comparing `screen_before` with `screen_now`, did `last_action` move the `task` closer to completion?",
        whenTrue: "The screen changed in a way that advances the task toward its goal",
        whenFalse: "The screen did not change, or changed in a way that does not advance the task"
      ),
      ID.unchanged: .noul(
        instructions:
          "Are `screen_before` and `screen_now` describing effectively the same screen state?",
        whenTrue: "The two descriptions show the same screen; nothing meaningful differs",
        whenFalse: "The screen changed in some meaningful way"
      ),
      ID.blocked: .noul(
        instructions:
          "Does `screen_now` show a login wall, permission prompt, CAPTCHA, paywall, age gate, or error page that prevents the `task` from continuing?",
        whenTrue:
          "Something external is blocking progress and the agent cannot resolve it by acting",
        whenFalse: "Nothing is blocking progress"
      ),
      ID.taskDone: .noul(
        instructions:
          "Given `task`, does `screen_now` show that the entire task is now complete?",
        whenTrue: "The task's final goal is visibly achieved on screen",
        whenFalse: "The task is not yet complete, or only partly complete"
      ),
      ID.looping: .noul(
        instructions:
          "Does `recent_history` show the same action being repeated without the screen changing?",
        whenTrue: "The same or nearly the same action repeats with no resulting change",
        whenFalse: "Actions are varying, or the screen is changing between them"
      ),

      // -- Selection ----------------------------------------------------
      //
      // `sufficient` is deliberately a Noul, not part of the Choice. A
      // Choice's probabilities sum to 1, so *something* always wins even
      // when the right target is absent from the list. This unnormalised
      // companion is the only thing that can say "none of these". Without
      // it the agent confidently clicks the nearest wrong thing.

      ID.sufficient: .noul(
        instructions:
          "Is the element list in `screen_now` enough to carry out `plan_step`, or would an image of the screen be needed to find the right target?",
        whenTrue:
          "The listed elements contain the right target and it can be identified from the list alone",
        whenFalse:
          "The target is absent from the list, or cannot be distinguished without seeing the screen"
      ),

      // -- Intent risk: advisory only -----------------------------------
      //
      // Asked about `plan_step` — the INTENT — never the resolved element.
      // The element-specific half of the safety decision is deterministic
      // and lives in `LabelDenylist`.
      //
      // Failure mode this cannot catch: a fork bomb scored 0.15 because
      // Jev pattern-matches semantics and does not parse shell syntax, and
      // a semantic reframing ("inside a throwaway container") moved a
      // destructive command from 0.98 to 0.42. What catches it: nothing
      // here. The irreversible boundary is deterministic and this battery
      // never reaches it.

      ID.riskDestructive: .noul(
        instructions:
          "Would carrying out `plan_step` permanently destroy or overwrite data, with no way to undo it?",
        whenTrue: "Data is destroyed or overwritten and cannot be brought back",
        whenFalse: "Nothing is destroyed, or the change can be undone"
      ),
      ID.riskOutbound: .noul(
        instructions:
          "Would carrying out `plan_step` send information to another person, publish it, or transmit it off this machine?",
        whenTrue: "Information leaves the machine or becomes visible to others",
        whenFalse: "The effect stays local to this machine"
      ),
      ID.riskCredential: .noul(
        instructions:
          "Would carrying out `plan_step` read, enter, or expose a password, API key, token, or other credential?",
        whenTrue: "A credential is read, entered, or exposed",
        whenFalse: "No credential is involved"
      ),
    ]

    // -- Right thing, wrong instance --------------------------------------
    //
    // UNMEASURED. The other five verification questions all answer
    // *correctly* while the agent composes from the wrong account — traced
    // on a real task. Unlike the login-wall miss, no second question
    // rescues it, because nobody asked.
    //
    // Skipped when the task names no instance. Asking about a context the
    // task never named invents one.
    if includeWrongContext {
      q[ID.wrongContext] = .noul(
        instructions:
          "Does `screen_now` show a different account, mailbox, document, workspace, or repository than the one named in `task_context`?",
        whenTrue: "The screen identifies a specific one, and it is not the one named",
        whenFalse: "It is the one named, or the screen does not identify one either way"
      )
    }

    // A Choice with no options is not a question. When perception produced
    // nothing, the batch still carries verification — which is what tells
    // the loop whether the screen is blocked, done, or merely empty.
    if !candidates.isEmpty {
      q[ID.target] = .choice(
        instructions:
          "Which element in `candidates` should be acted on to carry out `plan_step` on the current screen?",
        criteria: candidates
      )
    }

    return q
  }

  /// Questions deliberately NOT asked, each a documented `jev-1.13` failure
  /// mode. Listed here so a future contributor finds the reasoning before
  /// adding one back:
  ///
  /// | Not asked | Why | Done by |
  /// |---|---|---|
  /// | "How many X are on screen?" | does not count reliably | `candidates.count` |
  /// | "Is date A before date B?" | reads dates as text, not ordered quantities | `Foundation.Date` |
  /// | "What is the total?" | not a calculator | arithmetic in code |
  /// | "Write the post text" | not trained to generate text | the host agent |
  /// | "What should we do next?" | not an agent; does not choose its next action | the host agent |
  /// | "Is this element at these coordinates?" | no vision, no spatial reasoning | bounds in code |
  /// | "Does this element publish?" | attacker-influenceable; safety-critical | `LabelDenylist` |
  public static let deliberatelyNotAsked = 7
}
