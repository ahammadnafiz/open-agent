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
      try await type(text, into: handle)
      return ExecutionResult(dispatched: true, via: .bidi)

    case .scroll:
      // **A scroll is not a click.** Bundled into the branch below, `scroll`
      // dispatched a `pointerDown`/`pointerUp` at the target — so a plan that
      // asked to see further down a list of issues pressed the first one
      // instead, navigated away, and the next observation answered about
      // somewhere else entirely. The wheel is what the verb means.
      //
      // **And a wheel names a point, not an element.** A plan reaches here
      // with no target now (`PlanStep.needsTarget`), because the thing it
      // wants to scroll is a container the snapshot never collects — so the
      // middle of the viewport is the answer, and no selection call is spent
      // arriving at it. An explicit target still works: `act --kind scroll
      // --target e17` scrolls the pane that element sits in.
      let point: CGPoint
      if action.target != nil {
        point = try await validate(Self.handle(action))
      } else if let centre = await source.viewportCentre() {
        point = centre
      } else {
        throw ExecutionError.actionUnavailable(
          role: "bidi", wanted: "a laid-out viewport to scroll")
      }
      try await client.performActions([Self.scrollSequence(at: point)])
      return ExecutionResult(dispatched: true, via: .bidi)

    case .click, .focus, .select, .publish, .send, .delete, .purchase:
      let handle = try Self.handle(action)
      let point = try await validate(handle)
      try await client.performActions([Self.clickSequence(at: point)])
      return ExecutionResult(dispatched: true, via: .bidi)
    }
  }

  /// Types `text`, then confirms the field holds exactly `text`.
  ///
  /// **Typing was three assumptions in a row and no check.** Focus was asked
  /// for and the answer discarded; the field was cleared and nobody looked;
  /// the keys were sent and nothing read them back. Every one of those can
  /// fail quietly — a wrapper element that takes focus but cannot hold a
  /// caret, an editor that swallows select-all, a handle that resolves to the
  /// label beside the box rather than the box — and the failure they produce
  /// together is a field holding the message twice:
  /// `hello world from open-agenthello world from open-agent`.
  ///
  /// Checking makes the operation idempotent, which is the property that
  /// actually matters. However many times anything asks for this text to be
  /// typed — a ladder retry, a resumed plan, a second run over a composer
  /// someone left open — the field ends up holding it once or the step fails
  /// saying so. The cause no longer has to be enumerated to be survived.
  ///
  /// Two attempts, then refuse. Continuing on to a `publish` with the wrong
  /// text in the box is the outcome worth failing to avoid.
  ///
  /// **The first attempt types as fast as the wire allows; only the retry
  /// paces itself.** The cadence exists so a page that reacts per keystroke
  /// gets time to react, but almost none of them need it, and it is not
  /// cheap: every `pause` tick costs what it asks for plus about 45 ms of
  /// WebDriver overhead, which measured as `act=2147ms` to enter a 42-
  /// character post on X against `act=518ms` for the same text with no pauses.
  ///
  /// Retrying a failure with the identical strategy is just waiting for a
  /// different answer, so the two attempts are now *different* attempts: burst
  /// first, and if the field disagrees about what it holds, type it again the
  /// slow way. The read-back is what makes this safe to try — a page that
  /// genuinely needs the cadence says so, in the only way that matters, and
  /// gets it.
  private func type(_ text: String, into handle: String) async throws {
    let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var found = ""

    for attempt in 1...Self.typeAttempts {
      let paced = attempt > 1
      try await focus(handle)
      try await client.performActions([Self.clearSequence()])
      try await client.performActions([Self.keySequence(text, paced: paced)])

      found = try await fieldText(handle)
      if found.trimmingCharacters(in: .whitespacesAndNewlines) == wanted { return }
      Log.warn(
        "typing attempt \(attempt) left \(found.count) characters where \(text.count) "
          + "were asked for; retyping\(paced ? "" : " at keystroke pace")")
    }

    throw ExecutionError.actionUnavailable(
      role: handle, wanted: "a field holding exactly the text that was typed")
  }

  /// How many times to type before giving up. One retry: the common cause is a
  /// field that was not ready on the first pass, and a field that refuses
  /// twice is not going to yield to a third.
  private static let typeAttempts = 2

  /// What the field holds now — `value` for inputs, rendered text for a
  /// `contenteditable`.
  private func fieldText(_ handle: String) async throws -> String {
    let data = try await client.evaluate(
      """
      (() => {
        const el = window.__openAgent?.nodes?.get(\(Self.numeric(handle)));
        if (!el) return { text: "" };
        const v = ("value" in el && el.value !== undefined && el.value !== null)
          ? el.value : el.innerText;
        return { text: String(v ?? "") };
      })()
      """
    )
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = raw["text"] as? String
    else { return "" }
    return text
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

  static func resolveScript(handle: String) -> String {
    """
    (() => {
      const el = window.__openAgent?.nodes?.get(\(numeric(handle)));
      if (!el || !el.isConnected) return { missing: true };
      // **Fingerprint the element before moving it.** The guard is
      // `role|left|top|disabled`, and `scrollIntoView` changes `top` by
      // construction — so resolving a target that was below the fold scrolled
      // it to the middle of the viewport and then accused it of having moved.
      // Measured on prosemirror.net: expected `textbox|377|852|0`, found
      // `textbox|377|321|0`, and the step was refused with "an unchanged
      // target". Same element, same node handle; the 531 points were ours.
      //
      // Every target that needs scrolling hit this, which is most targets on
      // a page longer than a screen.
      const role = window.__oaRole(el);
      const guard = window.__oaGuard(el, role);
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      const cx = Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1);
      const cy = Math.min(Math.max(r.top + r.height / 2, 0), window.innerHeight - 1);
      const top = document.elementFromPoint(cx, cy);
      const occluded = !(top && (top === el || el.contains(top) || top.contains(el)));
      return {
        x: cx, y: cy, occluded: occluded,
        // One definition, shared with the snapshot. See
        // `SnapshotScript.guardFunction` for why this used to be written twice
        // and why the two never matched — and note it is computed above, before
        // anything on this page has been scrolled.
        guard: guard,
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

  /// One wheel notch down, anchored on the target.
  ///
  /// A fixed delta rather than a payload: `ActionKind` carries no distance and
  /// no direction, and inventing either here would put a number in the audit
  /// log that the plan never authorised. Roughly a screen of a default
  /// viewport, which is what "scroll down to see more" means in practice.
  private static func scrollSequence(at point: CGPoint) -> [String: Any] {
    [
      "type": "wheel",
      "id": "openAgentWheel",
      "actions": [
        [
          "type": "scroll", "x": Int(point.x), "y": Int(point.y),
          "deltaX": 0, "deltaY": Constants.Execution.scrollDelta,
          "origin": "viewport",
        ]
      ],
    ]
  }

  /// Select-all, then delete — in whatever now has focus.
  ///
  /// **`type` means "this field says this", not "append this".** The recovery
  /// ladder retries a step by running it again, so a `type` that appended
  /// doubled the text it was retrying; and a field holding a draft ran the
  /// payload on to the end of it. Both produce a message that was composed
  /// correctly and is wrong on screen.
  ///
  /// Real key events rather than clearing the value through the DOM: a React
  /// application does not see an assignment to `.value`, and Instagram's
  /// composer is a `contenteditable` with no value to assign.
  private static func clearSequence() -> [String: Any] {
    let meta = "\u{E03D}"
    let backspace = "\u{E003}"
    return [
      "type": "key", "id": "openAgentKeyboard",
      "actions": [
        ["type": "keyDown", "value": meta],
        ["type": "keyDown", "value": "a"],
        ["type": "keyUp", "value": "a"],
        ["type": "keyUp", "value": meta],
        ["type": "keyDown", "value": backspace],
        ["type": "keyUp", "value": backspace],
      ],
    ]
  }

  /// - Parameter paced: whether to space the keystrokes out. False delivers
  ///   the whole string as fast as `performActions` will carry it, which is
  ///   what every field tried so far actually wants; `type(_:into:)` turns it
  ///   on for the retry when a field says otherwise.
  static func keySequence(_ text: String, paced: Bool = true) -> [String: Any] {
    var actions: [[String: Any]] = []
    // The pause is what makes typing look typed — `performActions` would
    // otherwise deliver a whole sentence in one frame. It is also, measured,
    // the only expensive thing in the sequence: the keystrokes themselves cost
    // nothing, and each `pause` tick costs roughly what it asks for plus 45 ms
    // of its own. See `Constants.Typing.webKeystrokeGroup`.
    //
    // So the cadence is bought in bursts. Every `group` characters, one pause
    // carries that whole group's worth of delay. The text arrives over the
    // same total interval it always did, in small bursts rather than evenly —
    // which is what hands actually do — for a quarter of the overhead.
    let group = max(1, Constants.Typing.webKeystrokeGroup)
    var sincePause = 0
    for character in text {
      let value = String(character)
      actions.append(["type": "keyDown", "value": value])
      actions.append(["type": "keyUp", "value": value])
      sincePause += 1
      if paced, sincePause == group {
        actions.append([
          "type": "pause",
          "duration": Constants.Typing.webKeystrokeMilliseconds * group,
        ])
        sincePause = 0
      }
    }
    // No trailing pause. Nothing follows the last character, so a final wait
    // buys no cadence and costs another tick's overhead; `settle` is what
    // gives the page time to react.
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
