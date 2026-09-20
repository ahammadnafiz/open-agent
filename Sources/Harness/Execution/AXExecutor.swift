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
      if let element = try resolveIfTargeted(action) {
        // There is no AX action for a keystroke, so the element is
        // focused first and the event is synthesized at the HID layer.
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      }
      try KeySynthesis.press(key)
      return ExecutionResult(dispatched: true, via: .ax)

    case .type:
      guard let text = action.payload else {
        throw ExecutionError.missingPayload(kind: action.kind)
      }
      let element = try resolveRequired(action)
      // Try the attribute first — it is atomic and fires the right
      // notifications on well-behaved Cocoa controls.
      let set = AXUIElementSetAttributeValue(
        element, kAXValueAttribute as CFString, text as CFTypeRef
      )
      if set != .success {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try KeySynthesis.type(text)
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

  /// Launches an application by name.
  ///
  /// `/usr/bin/open` rather than `NSWorkspace`: `Harness` is declared headless
  /// in `Package.swift` and importing AppKit here to launch a process would
  /// trade that boundary for nothing. `open` is also what waits for an already
  /// running instance to come forward, which is the common case.
  static func launch(app name: String) throws {
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
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?
      .post(tap: .cghidEventTap)
  }

  /// Types text as real key events.
  ///
  /// Synthetic `value` assignment does not fire the listeners modern
  /// applications depend on, so this is the fallback whenever setting
  /// `kAXValueAttribute` fails.
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
      up.post(tap: .cghidEventTap)
    }
  }
}
