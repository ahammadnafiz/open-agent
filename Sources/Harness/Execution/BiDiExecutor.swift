import CoreGraphics
import Foundation

/// Tier 1 execution, over WebDriver BiDi.
///
/// Dispatches **real input events** through `input.performActions`, never a
/// synthetic `value` assignment. Assigning `value` updates what is on screen and
/// fires none of the listeners a modern web application depends on, so the field
/// looks filled and the page never learns about it — a failure that looks like
/// success in a screenshot.
///
/// Every action is validated against the snapshot that selected it before it
/// runs. `browser-use/jev-ultrafast` calls these guards, and they are what turns
/// "the page changed under me" from a silent misclick into a refusal — ADR 0010.
public struct BiDiExecutor: Executor {
  private let client: BiDiClient
  private let source: BiDiSource

  public init(client: BiDiClient, source: BiDiSource) {
    self.client = client
    self.source = source
  }

  public func execute(_ action: Action) async throws -> ExecutionResult {
    switch action.kind {
    case .navigate:
      guard let url = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      try await client.navigate(to: url)
      return ExecutionResult(dispatched: true, via: .bidi)

    case .wait:
      try await Task.sleep(for: Constants.Execution.waitDuration)
      return ExecutionResult(dispatched: true, via: .bidi)

    case .read:
      return ExecutionResult(dispatched: true, via: .bidi)

    case .openApp:
      // The agent owns its browser and launches it before the loop starts —
      // the debug port can only be set at process start, so there is nothing to
      // open from in here. ADR 0002.
      throw ExecutionError.actionUnavailable(
        role: "bidi", wanted: "openApp (the browser is launched before the loop)"
      )

    case .pressKey:
      guard let key = action.key else {
        throw ExecutionError.unknownKey(action.payload ?? "<nil>")
      }
      if let handle = try? Self.handle(action) {
        try await focus(handle)
      }
      try await client.performActions([Self.keySequence(Self.webDriverKey(key))])
      return ExecutionResult(dispatched: true, via: .bidi)

    case .type:
      guard let text = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      let handle = try Self.handle(action)
      try await validate(handle)
      try await focus(handle)
      try await client.performActions([Self.keySequence(text)])
      return ExecutionResult(dispatched: true, via: .bidi)

    case .click, .scroll, .focus, .select, .publish, .send, .delete, .purchase:
      let handle = try Self.handle(action)
      let point = try await validate(handle)
      try await client.performActions([Self.clickSequence(at: point)])
      return ExecutionResult(dispatched: true, via: .bidi)
    }
  }

  // MARK: - Target validation

  /// Re-resolves the element, scrolls it into view, and confirms it still looks
  /// the way it did when it was chosen.
  ///
  /// Returns the click point, computed here from the element's **own** bounding
  /// box at act time. That is the ADR 0007 exception and nothing else: the
  /// identity that reached the denylist and the confirmation sheet was the
  /// element, not this point, and the point exists only inside this call.
  @discardableResult
  private func validate(_ handle: String) async throws -> CGPoint {
    let expected = await source.guardFingerprint(handle)
    let script = Self.resolveScript(handle: handle)
    let data = try await client.evaluate(script)

    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ExecutionError.axFailed(code: -1)
    }
    if (raw["missing"] as? Bool) == true {
      // The node is gone. Re-observing is the loop's job; refusing is ours.
      throw ExecutionError.actionUnavailable(role: handle, wanted: "a live node")
    }
    if (raw["occluded"] as? Bool) == true {
      throw ExecutionError.windowNotVisible
    }
    if let fingerprint = raw["guard"] as? String, let expected, fingerprint != expected {
      Log.warn("bidi target \(handle) is stale: expected \(expected), found \(fingerprint)")
      throw ExecutionError.actionUnavailable(role: handle, wanted: "an unchanged target")
    }
    guard let x = raw["x"] as? Double, let y = raw["y"] as? Double else {
      throw ExecutionError.axFailed(code: -1)
    }
    return CGPoint(x: x, y: y)
  }

  private func focus(_ handle: String) async throws {
    _ = try await client.evaluate(
      """
      (() => {
        const el = window.__openAgent?.nodes?.get(\(Self.numeric(handle)));
        if (!el) return { ok: false };
        el.focus({ preventScroll: false });
        return { ok: true };
      })()
      """
    )
  }

  private static func handle(_ action: Action) throws -> String {
    guard let target = action.target, case .dom(let handle, _, _, _) = target else {
      throw ExecutionError.missingTarget(kind: action.kind)
    }
    return handle
  }

  /// `e17` → `17`. The prefix keeps candidate ids out of the integer namespace
  /// that mark indices and score levels already share.
  private static func numeric(_ handle: String) -> String {
    String(handle.drop(while: { !$0.isNumber }))
  }

  private static func resolveScript(handle: String) -> String {
    """
    (() => {
      const el = window.__openAgent?.nodes?.get(\(numeric(handle)));
      if (!el || !el.isConnected) return { missing: true };
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      const cx = Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1);
      const cy = Math.min(Math.max(r.top + r.height / 2, 0), window.innerHeight - 1);
      const top = document.elementFromPoint(cx, cy);
      const occluded = !(top && (top === el || el.contains(top) || top.contains(el)));
      const role = el.getAttribute('role') || el.tagName.toLowerCase();
      const disabled = el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true';
      return {
        x: cx, y: cy, occluded: occluded,
        guard: [role, (el.innerText || el.value || '').trim().slice(0, 200),
                Math.round(r.left), Math.round(r.top), disabled ? 1 : 0].join('|'),
      };
    })()
    """
  }

  // MARK: - Input sequences

  private static func clickSequence(at point: CGPoint) -> [String: Any] {
    [
      "type": "pointer",
      "id": "openAgentMouse",
      "parameters": ["pointerType": "mouse"],
      "actions": [
        ["type": "pointerMove", "x": Int(point.x), "y": Int(point.y)],
        ["type": "pointerDown", "button": 0],
        ["type": "pointerUp", "button": 0],
      ],
    ]
  }

  private static func keySequence(_ text: String) -> [String: Any] {
    var actions: [[String: Any]] = []
    for character in text {
      let value = String(character)
      actions.append(["type": "keyDown", "value": value])
      actions.append(["type": "keyUp", "value": value])
    }
    return ["type": "key", "id": "openAgentKeyboard", "actions": actions]
  }

  /// WebDriver's Unicode private-use codepoints for non-printing keys.
  /// `Key` is closed at three for the reasons ADR 0008 gives; a fourth is the
  /// same kind of decision as that document, not a config change.
  private static func webDriverKey(_ key: Key) -> String {
    switch key {
    case .enter: "\u{E007}"
    case .tab: "\u{E004}"
    case .escape: "\u{E00C}"
    }
  }
}
