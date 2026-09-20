import AppKit
import Harness
import SwiftUI

/// The `HUDBridge` the executable provides to the headless loop.
///
/// This is the only place the overlay and the approval sheet are reachable from
/// `Harness`, which never imports AppKit.
struct AppHUD: HUDBridge {

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
    await CursorOverlay.shared.press()
    return try await body()
  }

  func confirm(_ request: ConfirmationRequest) async -> Bool {
    await ApprovalSheet.present(request)
  }
}
