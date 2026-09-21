import ApplicationServices
import CoreGraphics
import Foundation

/// Tier 2 execution. Dispatches to an element.
///
/// **Mostly without moving a pointer.** `click`, `type`, `focus` and the gated
/// kinds go through `AXPress` and move no system cursor at all, which is what
/// lets the overlay draw the only arrow on screen. `doubleClick`, `rightClick`,
/// `hover` and `drag` cannot: the accessibility API has no second press, no
/// secondary press, no hover and no drag, so those four post real HID events —
/// and therefore carry the same preconditions `CapturedExecutor` does, because
/// a synthesized event lands on whatever is topmost at that point rather than
/// on the element it was aimed at. SPEC.md § Boundaries.
public struct AXExecutor: Executor {
  private let source: AXSource

  public init(source: AXSource) { self.source = source }

  public func execute(_ action: Action) async throws -> ExecutionResult {
    switch action.kind {
    case .wait:
      try await Task.sleep(for: Constants.Execution.waitDuration)
      return ExecutionResult(dispatched: true, via: .ax)

    case .read:
      // Reading is perception, already done. Nothing to dispatch.
      return ExecutionResult(dispatched: true, via: .ax)

    case .pressKey:
      guard let key = action.key else {
        throw ExecutionError.unknownKey(action.payload ?? "<nil>")
      }
      // There is no AX action for a keystroke, so the event is synthesized at
      // the HID layer — and it goes to the frontmost application. Raising it
      // first is the whole point; see `settleFocus`.
      let settled =
        if let element = try resolveIfTargeted(action) {
          Self.settleFocus(element, pid: source.pid)
        } else {
          Self.settleFrontmost(pid: source.pid)
        }
      guard settled else { throw ExecutionError.focusNotAccepted }
      try KeySynthesis.press(key)
      return ExecutionResult(dispatched: true, via: .ax)

    case .type:
      guard let text = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      let element = try resolveRequired(action)
      let before = Self.stringValue(of: element)
      // Try the attribute first — it is atomic and fires the right
      // notifications on well-behaved Cocoa controls.
      let set = AXUIElementSetAttributeValue(
        element, kAXValueAttribute as CFString, text as CFTypeRef
      )
      if set != .success
        || Self.writeWasIgnored(text, before: before, after: Self.stringValue(of: element))
      {
        guard Self.settleFocus(element, pid: source.pid) else {
          throw ExecutionError.focusNotAccepted
        }
        try KeySynthesis.type(text)
        // Keystrokes go to whatever holds focus, so where they landed is a
        // question worth actually asking. When the element can answer it and
        // says the text is not there, the step failed — and saying so lets the
        // ladder act, instead of the next step finding a screen that does not
        // match the route. A control that reports no value at all is not
        // evidence of failure, so it is left alone.
        let after = Self.stringValue(of: element)
        if after != nil, Self.writeWasIgnored(text, before: before, after: after) {
          throw ExecutionError.focusNotAccepted
        }
      }
      return ExecutionResult(dispatched: true, via: .ax)

    case .focus:
      let element = try resolveRequired(action)
      let result = AXUIElementSetAttributeValue(
        element, kAXFocusedAttribute as CFString, kCFBooleanTrue
      )
      guard result == .success else {
        throw ExecutionError.axFailed(code: Int(result.rawValue))
      }
      return ExecutionResult(dispatched: true, via: .ax)

    case .openApp:
      guard let name = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      try Self.launch(app: name)
      // **`open -a` returns when the app has been asked to come forward, not
      // when it has.** Activation often crosses a Space, and a Space transition
      // animates — during it the window server does not report the window as
      // on-screen. The next perception then failed with `windowNotOnScreen`
      // about an app that was opening exactly as instructed, one step after
      // `openApp` reported success.
      //
      // So the step is not done until there is something to look at. That is
      // also what makes `dispatched` mean what the rest of the system reads it
      // as meaning.
      guard Self.waitForWindow(app: name) else {
        throw ExecutionError.actionUnavailable(
          role: "openApp", wanted: "\(name) to put a window on screen")
      }
      return ExecutionResult(dispatched: true, via: .ax)

    case .navigate:
      // Navigation needs a browser, and ADR 0006 puts browser lifecycle and the
      // BiDi client off the v1 critical path. Enumerated rather than defaulted,
      // so wiring tier 1 is a change here and not a silent fallthrough.
      throw ExecutionError.actionUnavailable(
        role: "native", wanted: "navigate (ADR 0006: browser work is deferred)"
      )

    case .scroll:
      // **AXPress is not a scroll, and pressing the thing you wanted to
      // scroll past is worse than not scrolling at all.** `scroll` sat in the
      // branch below and dispatched a press at its target, so the verb
      // silently meant "click" everywhere it was planned. Enumerated and
      // refused rather than defaulted, exactly as `navigate` is: a native
      // scroll needs an HID wheel event against a verified window, and that
      // is a change with its own reversibility review, not a line here.
      throw ExecutionError.actionUnavailable(
        role: "native", wanted: "scroll (no AX action scrolls; a press is not a substitute)"
      )

    case .setValue:
      // **Foley's *quantify* without a drag.** A slider, stepper or progress
      // control carries a settable `AXValue`, so the value is written rather
      // than dragged to — which is the difference between an action a
      // confirmation can describe ("Zoom = 150") and one it cannot ("drag to
      // (847,203)").
      guard let value = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      let element = try resolveRequired(action)
      try Self.write(value: value, to: element)
      return ExecutionResult(dispatched: true, via: .ax)

    case .doubleClick, .rightClick, .hover:
      // No AX action exists for any of these — `AXPress` is a single primary
      // press and nothing else. They are synthesized at the HID layer against
      // the element's own frame, which is `.captured`-style actuation reached
      // from a named element, so the identity in the log is still the label.
      let element = try resolveRequired(action)
      let centre = try Self.pointerTarget(element, pid: source.pid, label: action.target?.label)
      // **A hover must not take focus.** `settleFocus` raises the app *and*
      // focuses the element, and focusing is a side effect nobody asked for
      // from a verb whose whole meaning is "arrive without pressing" — it moves
      // the caret out of whatever the user or an earlier step was typing into.
      // Being frontmost is still required, or the event goes elsewhere.
      let settled =
        action.kind == .hover
        ? Self.settleFrontmost(pid: source.pid)
        : Self.settleFocus(element, pid: source.pid)
      guard settled else { throw ExecutionError.focusNotAccepted }
      switch action.kind {
      case .doubleClick: try PointerSynthesis.doubleClick(at: centre)
      case .rightClick: try PointerSynthesis.rightClick(at: centre)
      default: try PointerSynthesis.move(to: centre)
      }
      return ExecutionResult(dispatched: true, via: .ax)

    case .drag:
      // Both ends are named elements — ADR 0001 — and both are resolved before
      // anything moves. A drag that discovers halfway through that it has
      // nowhere to let go has already picked the thing up.
      let element = try resolveRequired(action)
      guard let destinationRef = action.destination else {
        throw ExecutionError.missingDestination(reason: "a drag must name where it lets go")
      }
      guard case .ax(let destinationPath, _, _) = destinationRef else {
        throw ExecutionError.missingDestination(
          reason: "the destination is not a native element — a drag cannot cross worlds in "
            + "one step")
      }
      guard let destination = source.resolve(path: destinationPath) else {
        throw ExecutionError.missingDestination(
          reason: "the destination no longer resolves — observe again")
      }
      let from = try Self.pointerTarget(element, pid: source.pid, label: action.target?.label)
      let to = try Self.pointerTarget(
        destination, pid: source.pid, label: destinationRef.label)
      // **A drag onto itself is a click wearing a drag's gate.** Zero-length
      // travel presses and releases on the same element, which is exactly what
      // `click` does — except it arrived through the irreversible-by-default
      // path, so the audit log records a move that never happened.
      guard from != to else {
        throw ExecutionError.actionUnavailable(
          role: "drag", wanted: "two different points (source and destination coincide)")
      }
      guard Self.settleFocus(element, pid: source.pid) else {
        throw ExecutionError.focusNotAccepted
      }
      try PointerSynthesis.drag(from: from, to: to)
      return ExecutionResult(dispatched: true, via: .ax)

    case .click, .select,
      .publish, .send, .delete, .purchase:
      let element = try resolveRequired(action)
      try perform(preferredActions: Self.pressLike, on: element)
      return ExecutionResult(dispatched: true, via: .ax)
    }
  }

  /// Writes a value and reads it back.
  ///
  /// **A refused write is the failure mode that matters here.** `AXUIElement`
  /// returns `.success` for a set that the control then clamps, rounds or
  /// ignores outright — a slider with a 0–100 range asked for 150 reports
  /// success and sits at 100. Reporting `dispatched: true` on that is the same
  /// class of lie `type` already learned not to tell, so the value is read back
  /// and a control that disagrees fails the step.
  ///
  /// A control that reports no value at all is not evidence of failure, and is
  /// left alone — the same rule `type` uses.
  static func write(value: String, to element: AXUIElement) throws {
    // **What the control already holds decides how to write, not whether the
    // string happens to parse as a number.** Coercing on `Double(value)` turned
    // `"007"` into 7 and `"0123"` into 123 in a text field, and the read-back
    // then compared numerically and agreed with itself — a wrong value reported
    // as a right one.
    let numeric = Self.holdsNumber(element)
    let wrote: AXError =
      if numeric, let number = Double(value) {
        AXUIElementSetAttributeValue(
          element, kAXValueAttribute as CFString, number as CFTypeRef)
      } else {
        AXUIElementSetAttributeValue(
          element, kAXValueAttribute as CFString, value as CFTypeRef)
      }
    guard wrote == .success else {
      throw ExecutionError.axFailed(code: Int(wrote.rawValue))
    }

    do {
      try ValueReadback.verify(
        wrote: value, read: Self.numericOrStringValue(of: element),
        range: Self.range(of: element), numeric: numeric)
    } catch let mismatch as ValueReadback.Mismatch {
      throw ExecutionError.actionUnavailable(
        role: "setValue", wanted: ValueReadback.describe(mismatch))
    }
  }

  /// Whether this control stores a number rather than text.
  static func holdsNumber(_ element: AXUIElement) -> Bool {
    AXPrimitives.copyValue(element, kAXValueAttribute as String) is NSNumber
  }

  /// The control's own bounds, when it publishes them. A slider that reports
  /// 0…1 and one that reports 0…100 need very different tolerances, and only
  /// the control can say which it is.
  static func range(of element: AXUIElement) -> (min: Double, max: Double)? {
    guard
      let low = AXPrimitives.copyValue(element, kAXMinValueAttribute as String) as? NSNumber,
      let high = AXPrimitives.copyValue(element, kAXMaxValueAttribute as String) as? NSNumber
    else { return nil }
    return (low.doubleValue, high.doubleValue)
  }

  /// A control's value as a string, whether it stores a number or text.
  static func numericOrStringValue(of element: AXUIElement) -> String? {
    guard let raw = AXPrimitives.copyValue(element, kAXValueAttribute as String) else {
      return nil
    }
    if let text = raw as? String { return text }
    if let number = raw as? NSNumber { return "\(number.doubleValue)" }
    return nil
  }

  /// The point a synthesized event should be aimed at, once every precondition
  /// for aiming one has been met.
  ///
  /// **SPEC.md § Boundaries, *Never*: "Synthesize a click without first raising
  /// the target window and verifying it is on screen. The click lands on
  /// whatever is topmost at that point."** `CapturedExecutor` has enforced this
  /// since ADR 0007 and tier 2 never needed it, because tier 2 never posted a
  /// pointer event. Four verbs now do, so the same check belongs here — an app
  /// that is frontmost by `kAXFrontmost` can still have no window on this
  /// Space, and the event then lands in whatever application does.
  static func pointerTarget(_ element: AXUIElement, pid: pid_t, label: String?) throws -> CGPoint {
    guard WindowGuard.hasVisibleWindow(pid: pid) else {
      throw ExecutionError.windowNotVisible
    }
    guard let frame = AXPrimitives.frame(element), frame.width > 0, frame.height > 0 else {
      throw ExecutionError.actionUnavailable(
        role: "native", wanted: "a frame for \(label ?? "the target")")
    }
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  /// Waits until an application has a window this process can actually see.
  ///
  /// A pid is not enough. An app that has launched, or been raised onto another
  /// Space, exists long before it has drawn anything here — and an empty
  /// observation reads as "that screen has nothing on it" rather than "it is
  /// still coming up", which is the distinction Q6 exists for.
  static func waitForWindow(app name: String) -> Bool {
    let deadline = Date().addingTimeInterval(Constants.AX.launchTimeoutSeconds)
    repeat {
      if let pid = try? WindowGuard.pid(forApp: name), WindowGuard.hasVisibleWindow(pid: pid) {
        return true
      }
      usleep(Constants.AX.launchPollMicroseconds)
    } while Date() < deadline
    return false
  }

  /// Brings the application forward and aims it at the element, so that a
  /// synthesized key lands where it was pointed.
  ///
  /// **A HID event goes to the frontmost application, not to an element.** That
  /// is the invariant that actually decides where a keystroke ends up, and it
  /// is the one checked here. Asking instead whether the *element* reports
  /// focus was the wrong question, and it refused work that would have
  /// succeeded: measured on WhatsApp, the compose field holds the caret, shows
  /// the typed draft in the chat list, and still reports neither `kAXFocused`
  /// nor a matching `kAXFocusedUIElement`. Enter was refused on a field that
  /// visibly had focus.
  ///
  /// So element focus is *requested* and not *required* — it is what puts the
  /// caret in the right field on toolkits that implement it, and plenty do not.
  /// Being frontmost is required, because without it the key goes to whatever
  /// application is, which is how a send ends up typed into a terminal.
  ///
  /// The app is raised first and the element focused second: focusing something
  /// inside a background application moves nothing the keyboard can see.
  ///
  /// Synchronous on purpose. `AXUIElement` is not `Sendable` and must not cross
  /// a suspension point, and the wait is bounded.
  static func settleFocus(_ element: AXUIElement, pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

    let deadline = Date().addingTimeInterval(Constants.Typing.focusTimeoutSeconds)
    repeat {
      if isFrontmost(app) { return true }
      usleep(Constants.Typing.focusPollMicroseconds)
    } while Date() < deadline
    return false
  }

  /// Brings an application forward with no element in mind.
  ///
  /// The same precondition, for the steps that name no target.
  static func settleFrontmost(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(Constants.Typing.focusTimeoutSeconds)
    repeat {
      if isFrontmost(app) { return true }
      usleep(Constants.Typing.focusPollMicroseconds)
    } while Date() < deadline
    return false
  }

  private static func isFrontmost(_ app: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value) == .success,
      let flag = value as? Bool
    else { return false }
    return flag
  }

  /// The element's `AXValue`, when it is a string.
  static func stringValue(of element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success
    else { return nil }
    return raw as? String
  }

  /// Whether the write reported success and changed nothing.
  ///
  /// **`AXUIElementSetAttributeValue` returning `.success` does not mean the
  /// value changed.** Measured on WhatsApp's search field: the write returned
  /// success, the field stayed empty, the step reported `dispatched=true`, and
  /// the search results the next step needed never appeared. The keystroke
  /// fallback below it existed for exactly this and was unreachable, because it
  /// was guarded on a return code that lies.
  ///
  /// This is mechanics, not verification — the distinction `Step.swift` is
  /// built around. Jev decides whether the *task* moved; this asks only whether
  /// the API did the thing it just said it did.
  ///
  /// The test is deliberately narrow: fall back only when the field still holds
  /// **exactly** what it held before. A field that transformed the text, or
  /// accepted part of it, has done *something*, and typing it again on top
  /// would duplicate it — a worse failure than the one being fixed, and one the
  /// next step's verification would have to untangle.
  static func writeWasIgnored(_ text: String, before: String?, after: String?) -> Bool {
    guard after != text else { return false }
    return after == before
  }

  /// Launches an application by name.
  ///
  /// `/usr/bin/open` rather than `NSWorkspace`: `Harness` is declared headless
  /// in `Package.swift` and importing AppKit here to launch a process would
  /// trade that boundary for nothing. `open` is also what waits for an already
  /// running instance to come forward, which is the common case.
  ///
  /// Public because the executable has to be able to launch an app *before*
  /// the loop exists: `AXSource` resolves a pid in `init`, so a plan whose
  /// first step is `openApp` cannot be perceived until that step has happened.
  public static func launch(app name: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", name]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw ExecutionError.actionUnavailable(role: "openApp", wanted: name)
    }
    guard process.terminationStatus == 0 else {
      throw ExecutionError.actionUnavailable(role: "openApp", wanted: name)
    }
  }

  /// Press-like actions, most specific first.
  ///
  /// **`AXPress` is not universal and assuming it is fails silently on exactly
  /// the elements that matter.** Measured: Finder items offer `AXOpen` and
  /// `AXShowMenu` but *not* `AXPress`; a window offers only `AXRaise`.
  static let pressLike = [
    kAXPressAction as String,
    "AXOpen",
    kAXConfirmAction as String,
    kAXPickAction as String,
  ]

  private func perform(preferredActions: [String], on element: AXUIElement) throws {
    let available = Set(AXPrimitives.actions(element))
    guard let chosen = preferredActions.first(where: available.contains) else {
      let role = AXPrimitives.string(element, kAXRoleAttribute as String) ?? "?"
      throw ExecutionError.actionUnavailable(
        role: role, wanted: preferredActions.joined(separator: "|")
      )
    }
    let result = AXUIElementPerformAction(element, chosen as CFString)
    guard result == .success else {
      throw ExecutionError.axFailed(code: Int(result.rawValue))
    }
  }

  /// Re-resolves the path **immediately before acting**. A path is an index
  /// chain from the window root and is stable only within one observation.
  private func resolveRequired(_ action: Action) throws -> AXUIElement {
    guard let element = try resolveIfTargeted(action) else {
      throw ExecutionError.missingTarget(kind: action.kind)
    }
    return element
  }

  private func resolveIfTargeted(_ action: Action) throws -> AXUIElement? {
    guard let target = action.target else { return nil }
    guard case .ax(let path, _, _) = target else {
      throw ExecutionError.missingTarget(kind: action.kind)
    }
    guard let element = source.resolve(path: path) else {
      throw ExecutionError.axFailed(code: Int(AXError.invalidUIElement.rawValue))
    }
    return element
  }
}

/// CGEvent keyboard synthesis.
///
/// The virtual key codes below are **hardware constants, not tunables**, which
/// is why they are here rather than in `Constants.swift`. That file exists so a
/// human can review every value that decides *behaviour*; ANSI keycodes decide
/// nothing and padding the review surface with them hides the values that do.
enum KeySynthesis {
  private static let virtualKeys: [Key: CGKeyCode] = [
    .enter: 36,  // kVK_Return
    .tab: 48,  // kVK_Tab
    .escape: 53,  // kVK_Escape
    .up: 126, .down: 125, .left: 123, .right: 124,
    .home: 115, .end: 119, .pageUp: 116, .pageDown: 121,
    .backspace: 51,  // kVK_Delete — the key marked "delete" on an Apple keyboard
    .forwardDelete: 117,  // kVK_ForwardDelete
    .space: 49,
    .selectAll: 0,  // kVK_ANSI_A, with command — see `modifiers`
    .undo: 6,  // kVK_ANSI_Z, with command
  ]

  /// Modifiers a named combination carries. Empty for a plain key.
  ///
  /// The vocabulary is a closed set of **meanings**, not of modifier+key
  /// pairs: `selectAll` is reviewable in a way `cmd+shift+<anything>` is not,
  /// and it keeps the enum something a human can read down and reason about.
  private static let modifiers: [Key: CGEventFlags] = [
    .selectAll: .maskCommand,
    .undo: .maskCommand,
  ]

  /// Whether this key can actually be sent.
  ///
  /// Exists so a test can assert the enum and this table never drift. A key
  /// that parses in a plan and has no keycode fails at the executor instead —
  /// mid-run, on someone's screen, which is the worst place to discover it.
  static func canSynthesize(_ key: Key) -> Bool { virtualKeys[key] != nil }

  static func press(_ key: Key) throws {
    guard let code = virtualKeys[key] else {
      throw ExecutionError.unknownKey(key.rawValue)
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ExecutionError.graphicsFailed(stage: "CGEventSource")
    }
    let flags = modifiers[key] ?? []
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    if !flags.isEmpty {
      down?.flags = flags
      up?.flags = flags
    }
    down?.post(tap: .cghidEventTap)
    usleep(Constants.Typing.keyHoldMicroseconds)
    up?.post(tap: .cghidEventTap)
  }

  /// Types text as real key events.
  ///
  /// Synthetic `value` assignment does not fire the listeners modern
  /// applications depend on, so this is the fallback whenever setting
  /// `kAXValueAttribute` fails.
  ///
  /// **Paced.** Posted back to back with no gap, characters arrive faster than
  /// an application drains its event queue and the surplus is dropped — a field
  /// that ends up holding a few of the letters, or none, after a step that
  /// reported success. The caller must have confirmed focus first; these events
  /// go to whatever holds it, not to any element.
  static func type(_ text: String) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ExecutionError.graphicsFailed(stage: "CGEventSource")
    }
    for character in text {
      var utf16 = Array(String(character).utf16)
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { continue }
      down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
      up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
      down.post(tap: .cghidEventTap)
      usleep(Constants.Typing.keyHoldMicroseconds)
      up.post(tap: .cghidEventTap)
      usleep(Constants.Typing.keystrokeIntervalMicroseconds)
    }
  }
}

/// CGEvent pointer synthesis.
///
/// **The accessibility API has no pointer.** `AXPress` is a single primary
/// press and there is no AX equivalent of a second click, a secondary click, a
/// hover or a drag — which is exactly why those four verbs did not exist. They
/// are synthesized at the HID layer instead, always against a frame read from a
/// named element, so the identity that reaches the log and the confirmation is
/// still the label and never the point.
///
/// Sibling of `KeySynthesis`. **Its timings are NOT here**, unlike that enum's
/// keycodes: an ANSI keycode decides nothing, while how long a drag hovers over
/// a drop target before releasing decides whether the drop is accepted. That is
/// behaviour, so it lives in `Constants.swift` where a human reviews it.
enum PointerSynthesis {

  /// Gap between the two presses of a double click.
  ///
  /// Below the system double-click interval or the pair is read as two separate
  /// clicks — which is not a slower double click, it is a different gesture.
  /// Gap between the two presses of a double click.
  ///
  /// **Its own constant, not the drag hold.** These were briefly the same
  /// number, which coupled two unrelated things: raising the drop-target hover
  /// past the system double-click interval would have silently turned
  /// `doubleClick` into two ordinary clicks, and nothing would have said so.
  private static var doubleClickGapMicroseconds: UInt32 {
    UInt32(Constants.Execution.doubleClickGapMilliseconds) * 1_000
  }

  /// Pause after pressing and again before releasing, so a drop target that
  /// validates on hover has a frame to do it in.
  private static var dropHoverMicroseconds: UInt32 {
    UInt32(Constants.Execution.dragHoldMilliseconds) * 1_000
  }

  /// Steps a drag is broken into.
  ///
  /// **A drag is not a teleport.** Applications track `mouseDragged` to decide
  /// what is being dragged and where it may land; a down at the source followed
  /// by an up at the destination, with nothing between, is a gesture most
  /// toolkits never recognise as a drag at all — the drop target never
  /// highlights, and the item is left where it started.
  private static var dragSteps: Int { Constants.Execution.dragSteps }
  private static var dragStepMicroseconds: UInt32 {
    UInt32(Constants.Execution.dragStepMilliseconds) * 1_000
  }

  private static func event(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton)
    -> CGEvent?
  {
    CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
  }

  private static func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left)
    throws
  {
    guard let e = event(type, point, button) else {
      throw ExecutionError.graphicsFailed(stage: "CGEvent \(type.rawValue)")
    }
    e.post(tap: .cghidEventTap)
  }

  static func move(to point: CGPoint) throws {
    try post(.mouseMoved, point)
  }

  /// **Every press in this file is paired with a release that survives a
  /// throw.** `post` fails when the window server refuses an event, and a
  /// failure between down and up leaves the physical button held down system
  /// wide: from the user's point of view every subsequent mouse movement is a
  /// drag, and only a real click gets them out of it. The agent breaking the
  /// machine's pointer is a worse outcome than any step failing.
  static func rightClick(at point: CGPoint) throws {
    try post(.mouseMoved, point)
    usleep(Constants.Typing.keyHoldMicroseconds)
    try post(.rightMouseDown, point, .right)
    var released = false
    defer { if !released { try? post(.rightMouseUp, point, .right) } }
    usleep(Constants.Typing.keyHoldMicroseconds)
    try post(.rightMouseUp, point, .right)
    released = true
  }

  /// Two presses, with `clickState` set.
  ///
  /// **The gap alone does not make a double click.** macOS reads the second
  /// press as part of the same gesture only when the event carries
  /// `clickState == 2`; without it a well-behaved application sees two ordinary
  /// clicks however fast they arrive, and a file gets selected twice instead of
  /// opened.
  static func doubleClick(at point: CGPoint) throws {
    try post(.mouseMoved, point)
    usleep(Constants.Typing.keyHoldMicroseconds)

    try post(.leftMouseDown, point)
    var released = false
    defer { if !released { try? post(.leftMouseUp, point) } }
    usleep(Constants.Typing.keyHoldMicroseconds)
    try post(.leftMouseUp, point)
    released = true
    usleep(doubleClickGapMicroseconds)

    guard let down = event(.leftMouseDown, point, .left),
      let up = event(.leftMouseUp, point, .left)
    else { throw ExecutionError.graphicsFailed(stage: "CGEvent double click") }
    down.setIntegerValueField(.mouseEventClickState, value: 2)
    up.setIntegerValueField(.mouseEventClickState, value: 2)
    down.post(tap: .cghidEventTap)
    released = false
    usleep(Constants.Typing.keyHoldMicroseconds)
    up.post(tap: .cghidEventTap)
    released = true
  }

  /// Press at `from`, travel, release at `to`.
  static func drag(from: CGPoint, to: CGPoint) throws {
    try post(.mouseMoved, from)
    usleep(Constants.Typing.keyHoldMicroseconds)
    try post(.leftMouseDown, from)
    // The button is down from here. A throw anywhere in the travel below must
    // still put it back up — see `rightClick`.
    var released = false
    defer { if !released { try? post(.leftMouseUp, to) } }
    usleep(dropHoverMicroseconds)

    for step in 1...dragSteps {
      let t = Double(step) / Double(dragSteps)
      let point = CGPoint(
        x: from.x + (to.x - from.x) * t,
        y: from.y + (to.y - from.y) * t)
      try post(.leftMouseDragged, point)
      usleep(dragStepMicroseconds)
    }

    // A pause on the target before letting go. Drop targets validate on hover,
    // and releasing in the same frame the pointer arrives beats that check on
    // enough applications to be worth the milliseconds.
    usleep(dropHoverMicroseconds)
    try post(.leftMouseUp, to)
    released = true
  }
}
