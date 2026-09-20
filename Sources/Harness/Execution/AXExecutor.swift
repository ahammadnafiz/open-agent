import ApplicationServices
import CoreGraphics
import Foundation

/// Tier 2 execution. Dispatches to an element; moves no pointer.
///
/// That last part matters for the overlay: tiers 1–2 move no system cursor at
/// all, so the drawn cursor is the only thing on screen and there is no second
/// arrow to explain — unlike `CapturedExecutor`, which posts a real event.
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

    case .click, .scroll, .select,
      .publish, .send, .delete, .purchase:
      let element = try resolveRequired(action)
      try perform(preferredActions: Self.pressLike, on: element)
      return ExecutionResult(dispatched: true, via: .ax)
    }
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
  ]

  static func press(_ key: Key) throws {
    guard let code = virtualKeys[key] else {
      throw ExecutionError.unknownKey(key.rawValue)
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ExecutionError.graphicsFailed(stage: "CGEventSource")
    }
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?
      .post(tap: .cghidEventTap)
    usleep(Constants.Typing.keyHoldMicroseconds)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?
      .post(tap: .cghidEventTap)
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
