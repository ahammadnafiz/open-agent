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
  func executor(for ref: ElementRef?) throws -> any Executor
}

/// Dispatch from a ref to the executor that can act on it.
///
/// **Total over every `ElementRef` case.** A ref the harness can produce but
/// cannot act on is exactly the defect ADR 0007 was written to close; if a case
/// is ever added, this switch is where it must be handled rather than defaulted.
public struct ExecutorRegistry: ExecutorProviding {
  private let ax: AXExecutor
  private let captured: CapturedExecutor

  public init(ax: AXExecutor, captured: CapturedExecutor) {
    self.ax = ax
    self.captured = captured
  }

  public func executor(for ref: ElementRef?) throws -> any Executor {
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
      // Tier 1 is deferred off the v1 critical path by ADR 0006
      // (native-first sequencing). The case is enumerated rather than
      // defaulted so that adding BiDi is a compile error here, not a
      // silent fallthrough to the wrong executor.
      throw ExecutionError.actionUnavailable(
        role: "dom", wanted: "BiDiExecutor (ADR 0006: deferred)")
    }
  }
}
