import Foundation

/// Performs one action and reports **mechanics only**.
///
/// A click can be dispatched perfectly and change nothing. Only the next step's
/// Jev batch knows whether the task moved. Conflating the two is the failure
/// this architecture exists to prevent.
public protocol Executor: Sendable {
  func execute(_ action: Action) async throws -> ExecutionResult
}

/// Dispatch from a ref to the executor that can act on it.
///
/// A protocol so the loop can be tested without a screen, and so a fake can
/// assert exactly which actions reached execution.
public protocol ExecutorProviding: Sendable {
  func executor(for ref: ElementRef?, kind: ActionKind) throws -> any Executor
}

/// Dispatch from a ref to the executor that can act on it.
///
/// **Total over every `ElementRef` case.** A ref the harness can produce but
/// cannot act on is exactly the defect ADR 0007 was written to close; if a case
/// is ever added, this switch is where it must be handled rather than defaulted.
public struct ExecutorRegistry: ExecutorProviding {
  private let ax: AXExecutor
  private let captured: CapturedExecutor
  /// `nil` when the task never entered a browser. A task can cross the boundary
  /// mid-run — open Finder, drag a file into a page — so this is decided per
  /// step, not per task.
  private let bidi: BiDiExecutor?

  public init(ax: AXExecutor, captured: CapturedExecutor, bidi: BiDiExecutor? = nil) {
    self.ax = ax
    self.captured = captured
    self.bidi = bidi
  }

  public func executor(for ref: ElementRef?, kind: ActionKind) throws -> any Executor {
    // **`navigate` is a browser operation that happens to name no element.**
    // Routing every targetless action to the native executor sent it there
    // too, where it is refused by construction — so the browser tier's own
    // entry point was unreachable, and a `--browser` task died on step one
    // with "navigate (ADR 0006: browser work is deferred)" while a perfectly
    // good BiDi session sat open beside it.
    //
    // The rest still belong to AX: launching an application is a native
    // operation whatever the eventual target world turns out to be, and
    // waiting belongs to nobody in particular.
    if kind == .navigate, let bidi { return bidi }

    // No target: openApp / navigate / wait. These are app-level and the AX
    // executor owns them, because launching is a native operation whatever
    // the eventual target world turns out to be.
    guard let ref else { return ax }

    switch ref {
    case .ax:
      return ax
    case .captured:
      return captured
    case .dom:
      // Tier 1, landed by ADR 0010. Still enumerated rather than defaulted: a
      // ref the harness can produce but not act on is the defect ADR 0007 was
      // written to close.
      guard let bidi else {
        throw ExecutionError.actionUnavailable(
          role: "dom", wanted: "a browser session — run with --browser")
      }
      return bidi
    }
  }
}
