import Foundation

/// Produced once, at task start, by the host agent. A hypothesis about the route.
///
/// The agent is EXPECTED to depart from it. Departure is not failure — it is the
/// normal case, because a planner that has not seen the screen is guessing about
/// layout. The plan supplies intent for each step; the screen supplies reality.
public struct Plan: Codable, Sendable, Equatable {
  public let steps: [PlanStep]

  public init(steps: [PlanStep]) { self.steps = steps }

  /// `true` when the plan has no steps left to attempt at `index`.
  public func isExhausted(at index: Int) -> Bool { index >= steps.count }

  /// The app this plan wants opened before anything can be perceived, or `nil`.
  ///
  /// `AXSource` resolves a pid in `init`, so an app that is not running is a
  /// hard failure *before the loop starts* — which made a plan whose first step
  /// is `openApp` impossible to run at all. The executable needs to know, ahead
  /// of the loop, whether the plan itself asked for that launch.
  ///
  /// **Returning `nil` is the point.** It is what stops the agent launching an
  /// application nobody mentioned. Only a step the plan already declared, and
  /// only the one that is actually next — a plan that opens an app at step
  /// five has not asked for it at step one.
  ///
  /// - Parameter appName: the session's app, used when the step names a target
  ///   but carries no payload.
  public func launchTarget(atPlanIndex index: Int, appName: String) -> String? {
    guard let step = steps.dropFirst(max(0, index)).first, step.kind == .openApp else {
      return nil
    }
    let name = step.payload ?? appName
    return name.isEmpty ? nil : name
  }
}

/// One intent. Targets are named **semantically** — "the compose button" — never
/// as coordinates and never as element ids. The binary re-resolves the actual
/// element from the live screen through Jev, which is the whole reason a stale
/// plan is survivable.
public struct PlanStep: Codable, Sendable, Equatable {
  public let kind: ActionKind
  public let target: String
  public let payload: String?
  /// The planner's own claim. One of five inputs to `Irreversibility.classify`,
  /// and it can only ever raise the result — so a host that declares too much
  /// costs an extra confirmation, and one that declares too little is caught by
  /// the other four. See ADR 0001.
  public let declaredIrreversible: Bool

  /// Whether a step of this kind names an on-screen element.
  ///
  /// `openApp`, `navigate` and `wait` do not, so the loop must not send them
  /// through candidate selection — there is nothing to select, and routing them
  /// that way made the first step of the v1 reference task unreachable.
  ///
  /// **`scroll` does not either, and requiring one made it unplannable.** A
  /// wheel needs a point, not an element, and the point that means "scroll
  /// this page" is the middle of the viewport. But selection was still run
  /// against a name, and the thing a plan wants to scroll — a feed, a message
  /// list, a page — is a container, which `SnapshotScript` never collects
  /// because it is not actionable. So the name matched whatever was nearest:
  /// measured on a Facebook feed, nine `scroll the news feed` steps resolved
  /// to `Leave a comment`, `Leave a comment`, `View more comments`, and
  /// anchored the wheel on a comment box each time. Each one also cost a Jev
  /// selection call, and the run exhausted its budget at step 8 of 11.
  public static func needsTarget(_ kind: ActionKind) -> Bool {
    switch kind {
    case .openApp, .navigate, .wait, .scroll: false
    default: true
    }
  }

  public init(
    kind: ActionKind, target: String, payload: String?, declaredIrreversible: Bool = false
  ) {
    self.kind = kind
    self.target = target
    self.payload = payload
    self.declaredIrreversible = declaredIrreversible
  }

  private enum CodingKeys: String, CodingKey {
    case kind, target, payload
    case declaredIrreversible = "declared_irreversible"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(ActionKind.self, forKey: .kind)
    target = try c.decode(String.self, forKey: .target)
    payload = try c.decodeIfPresent(String.self, forKey: .payload)
    // Absent means "not declared", which is the weaker claim. A host that
    // omits the field must not accidentally assert irreversibility.
    declaredIrreversible = try c.decodeIfPresent(Bool.self, forKey: .declaredIrreversible) ?? false
  }
}
