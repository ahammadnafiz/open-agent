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
  public static func needsTarget(_ kind: ActionKind) -> Bool {
    switch kind {
    case .openApp, .navigate, .wait: false
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
