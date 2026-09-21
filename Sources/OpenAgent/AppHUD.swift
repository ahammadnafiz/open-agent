import AppKit
import Harness
import SwiftUI

/// The `HUDBridge` the executable provides to the headless loop.
///
/// This is the only place the overlay and the approval sheet are reachable from
/// `Harness`, which never imports AppKit.
struct AppHUD: HUDBridge {

  /// The application being driven. The overlay draws only while this is the
  /// application in front of the user — see `CursorOverlay.bind(toApplication:)`.
  let pid: pid_t

  /// **Narration and execution are one call.**
  ///
  /// The ring lands on the target, the user gets
  /// `Constants.HUD.anticipationSeconds` to object, and only then does the
  /// executor fire. Two separate calls could drift, and an overlay that rings
  /// element X while the executor acts on element Y is a confident, legible
  /// lie — worse than no overlay, because every correct step before it trained
  /// the user to believe this one.
  func narrating(
    _ action: Action,
    target: Element?,
    _ body: @Sendable () async throws -> ExecutionResult
  ) async throws -> ExecutionResult {
    guard Constants.HUD.motionEnabled, let target else {
      return try await body()
    }

    let intent: CursorIntent =
      Irreversibility.classify(action, target: target) == .irreversible
      ? .irreversible : .routine

    // On a captured step the real system pointer does the work, so a second
    // drawn arrow over it reads as a rendering glitch on precisely the step
    // where the least familiar thing is happening — Open Question Q9.
    let isCaptured = target.ref.sourceKind == .captured

    // Idempotent, and cheap after the first step. It is done here rather than
    // at construction because the overlay is main-actor isolated and this is
    // the first point in the step that is already on it.
    await CursorOverlay.shared.bind(toApplication: pid)
    await CursorOverlay.shared.move(
      to: target.bounds,
      verb: action.kind.rawValue,
      label: target.label.isEmpty ? (target.visionLabel ?? "") : target.label,
      intent: intent,
      showsCursor: !isCaptured
    )
    // `press()` runs on every step, captured or not. It is what clears the
    // target ring, and the ripple is truthful either way — a real click does
    // land there. Skipping it left the ring on screen permanently.
    //
    // **It runs alongside the executor, not in front of it.** `press()` is
    // documented as purely visual, and awaiting it first meant the real event
    // was dispatched 180 ms after the on-screen press had already finished —
    // a press ripple that was over before anything was pressed. Every step
    // paid it: 0.10s holding the ripple, 0.08s clearing the ring.
    //
    // Overlapping is also the truer rendering. A press should register on the
    // way down rather than on release, so the ripple and the dispatch being
    // the same moment is what the animation was claiming all along. The ring
    // still lands first and the anticipation window before it is untouched —
    // that pause is the user's time to object, and it is not a delay to win
    // back.
    async let ripple: Void = CursorOverlay.shared.press()
    do {
      let outcome = try await body()
      await ripple
      return outcome
    } catch {
      // The ring has to be cleared even when the step failed, or it stays on
      // screen pointing at an element nothing happened to.
      await ripple
      throw error
    }
  }

  func confirm(_ request: ConfirmationRequest) async -> Bool {
    await ApprovalSheet.present(request)
  }
}
