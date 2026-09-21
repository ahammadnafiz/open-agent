import Foundation

/// Errors are typed and exhaustive. No `throws` without a concrete error enum —
/// SPEC.md § Code Style.

/// Perception could not produce a usable element list.
public enum PerceptionError: Error, Equatable, Sendable {
  /// The accessibility API is not granted to *this binary*. The grant is
  /// per-binary: a freshly compiled executable is untrusted even when run
  /// from a granted terminal.
  case accessibilityNotTrusted
  /// No window could be resolved after `Constants.AX.windowRetries` attempts.
  /// `AXWindows` intermittently returns empty for windows that demonstrably
  /// exist — a single read is not a valid observation.
  case noWindow(app: String)
  /// The named application is not running.
  case appNotRunning(String)
  /// The walk hit `Constants.AX.walkDeadline` or `maxNodes` before finishing.
  /// Partial results are still returned; this is thrown only when nothing
  /// usable was collected.
  case walkTimedOut(app: String)
  /// The window exists but is minimized, off-Space, or otherwise not on
  /// screen. Observing it returns empty, which is indistinguishable from
  /// "nothing actionable here" — Open Question Q6.
  case windowNotOnScreen(app: String)
}

/// The deterministic candidate reduction refused to produce a set.
public enum CandidateError: Error, Equatable, Sendable {
  /// More than `Constants.Jev.maxCandidates` survived the filter.
  ///
  /// The step escalates to vision rather than silently truncating.
  /// **Truncation would remove the correct answer without anyone noticing**,
  /// which is the worst available failure — `docs/harness.md` §3.3.
  case tooManyCandidates(count: Int)
  /// Nothing survived the filter. The screen has no labelled, actionable,
  /// on-screen element.
  case noCandidates
}

/// Execution failed mechanically. Says nothing about task progress.
public enum ExecutionError: Error, Equatable, Sendable {
  /// A merged OCR line spans several controls and its centre lands on an
  /// arbitrary one of them. Splitting by gap was measured to be impossible.
  /// Refused outright — ADR 0007.
  case ocrLineNotActionable
  /// A point click lands on whatever is topmost *there*. Unlike tiers 1–2,
  /// which dispatch to an element, this can hit another application entirely.
  case windowNotVisible
  /// The element does not offer the action. Measured: Finder items offer
  /// `AXOpen`/`AXShowMenu` but not `AXPress`; assuming `AXPress` is universal
  /// fails silently on exactly the elements that matter.
  case actionUnavailable(role: String, wanted: String)
  /// The AX API rejected the call.
  case axFailed(code: Int)
  /// Focus was set and the application never accepted it.
  ///
  /// Refused rather than typed anyway. Keys posted at an element that does not
  /// have focus go wherever focus actually is — measured on WhatsApp, into the
  /// chat list, where the text acted as type-select and dismissed the panel the
  /// next step needed. A clean failure the ladder can escalate beats a
  /// successful-looking step that changed the wrong thing.
  case focusNotAccepted
  /// An action arrived with no target where one is required.
  case missingTarget(kind: ActionKind)
  /// A `drag` arrived with no destination, or with one this executor cannot
  /// reach.
  ///
  /// Separate from `missingTarget` because the two are fixed differently and a
  /// shared error hid the harder one: a `.ax` source with a `.dom` destination
  /// is a drag *across worlds* — the case `ExecutorRegistry` explicitly
  /// contemplates, "open Finder, drag a file into a page" — and reporting it as
  /// a missing target sends a host looking for a target it already supplied.
  case missingDestination(reason: String)
  /// An action arrived with no payload where one is required.
  case missingPayload(kind: ActionKind)
  /// `pressKey` carried something that is not a `Key`.
  case unknownKey(String)
  /// Screen Recording is not granted. Since ADR 0007 this gates *execution*
  /// at tiers 3–4, not just observation.
  case screenRecordingNotGranted
  /// A CoreGraphics or ImageIO call failed. Distinct from `axFailed` because
  /// the accessibility API was not involved and its error codes do not apply —
  /// reporting a bitmap-context failure as an AX error sends the reader to the
  /// wrong documentation.
  case graphicsFailed(stage: String)
}

/// The loop could not continue.
public enum LoopError: Error, Equatable, Sendable {
  /// A session id was supplied that has no state on disk.
  case unknownSession(String)
  /// `resume` was called on a session that is not waiting for anything.
  case sessionNotWaiting(String)
  /// The plan ran out of steps and Jev did not report the task done.
  case planExhausted
}
