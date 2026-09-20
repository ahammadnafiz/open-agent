import CoreGraphics
import Foundation

/// Tiers 3–4 execution. No element tree exists, so this **actuates with a
/// synthesized event** at a point computed from the target's own bounding box —
/// ADR 0007.
///
/// **This is the one file in the system where a coordinate exists.** If `x`/`y`
/// or a `CGPoint` appears in an `Action`, a plan, a Jev `state`, a model
/// response, or a step log's identity field, the design has been violated. The
/// point here is computed at act time, downstream of selection, the denylist and
/// the confirmation gate, from a target that was already named.
///
/// Three preconditions, each **enforced rather than assumed**:
///
/// 1. `.ocrLine` provenance is refused outright.
/// 2. The window must be provably on screen.
/// 3. The step log must carry the frame hash.
///
/// **Unmeasured.** ADR 0007 is the only decision in this project that rests on
/// reading the types rather than on numbers from this machine, and Open Question
/// Q7 calls this "the largest unknown in the system". Nothing here should be
/// trusted until `Probe captured-eval` exists.
public struct CapturedExecutor: Executor {
  private let pid: pid_t
  private let appName: String
  /// Hash of the frame the target's bounds were measured in. A bbox is
  /// meaningless without it, and a step without it is unreplayable.
  private let frameHash: @Sendable () -> String?

  public init(
    pid: pid_t,
    appName: String,
    frameHash: @escaping @Sendable () -> String?
  ) {
    self.pid = pid
    self.appName = appName
    self.frameHash = frameHash
  }

  public func execute(_ action: Action) async throws -> ExecutionResult {
    guard let target = action.target, case .captured(let bbox, _, let provenance) = target else {
      throw ExecutionError.missingTarget(kind: action.kind)
    }

    // 1. An OCR line box spans several controls and its centre lands on an
    //    arbitrary one of them. ADR 0005 measured that splitting by gap is
    //    impossible: inter-link and intra-link spacing are identical at
    //    every resolution (2/2 px at DPR 1, 6/5 px at DPR 3). There is no
    //    threshold to find, so this is the worst failure available and it is
    //    refused rather than mitigated.
    guard provenance != .ocrLine else {
      throw ExecutionError.ocrLineNotActionable
    }

    // Since ADR 0007, Screen Recording gates EXECUTION at these tiers, not
    // just observation — the bounds being acted on came from pixels.
    guard CGPreflightScreenCaptureAccess() else {
      throw ExecutionError.screenRecordingNotGranted
    }

    // 2. A point click lands on whatever is topmost THERE. Unlike tiers 1–2,
    //    which dispatch to an element, this can hit another application
    //    entirely. Open Question Q6 is a correctness prerequisite here.
    try raiseAndVerifyOnScreen()

    // 3. The bbox is meaningless without the frame it was measured in.
    guard let hash = frameHash() else {
      throw ExecutionError.windowNotVisible
    }

    guard bbox.area > 0 else { throw ExecutionError.windowNotVisible }
    let point = CGPoint(x: bbox.midX, y: bbox.midY)

    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ExecutionError.graphicsFailed(stage: "CGEventSource")
    }
    // Move first, then press. A press without a preceding move lands with
    // the pointer wherever the user last left it in some applications.
    CGEvent(
      mouseEventSource: source, mouseType: .mouseMoved,
      mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)
    CGEvent(
      mouseEventSource: source, mouseType: .leftMouseDown,
      mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)
    CGEvent(
      mouseEventSource: source, mouseType: .leftMouseUp,
      mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)

    return ExecutionResult(dispatched: true, via: .captured, frameHash: hash)
  }

  /// Verifies the target window is on screen, and fails loudly when it is not.
  ///
  /// Raising programmatically is deliberately **not** attempted here: measured
  /// during design, `unhide`, `activate`, clearing `AXMinimized` and `AXRaise`
  /// all failed to bring a window from another Space onto the current one. A
  /// raise that silently does nothing, followed by a click, is worse than a
  /// refusal — so this refuses.
  private func raiseAndVerifyOnScreen() throws {
    guard WindowGuard.hasVisibleWindow(pid: pid) else {
      throw ExecutionError.windowNotVisible
    }
  }
}
