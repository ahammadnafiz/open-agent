import CoreGraphics
import Foundation
import Testing

@testable import Harness

/// The five verbs added to close the gap between what the agent can express and
/// what a person actually does at a computer.
///
/// Foley, Wallace & Chan (1984) decompose graphical interaction into select,
/// position, orient, path, quantify and text entry. The original fourteen kinds
/// covered *select*, *text entry* and *quantify*-by-wheel completely, and
/// *position* and *path* not at all — because those two name a coordinate, and
/// ADR 0001 forbids an identity that is a coordinate.
///
/// The split these tests pin down is therefore not "mouse verbs are missing".
/// It is that a drag whose **both** endpoints are named elements stays inside
/// ADR 0001 — it can be shown in a confirmation, matched by the denylist and
/// read back out of a log a year later — while a drag to a bare point cannot,
/// and is still refused.
@Suite("New action kinds")
struct NewActionKindTests {

  static func ax(_ label: String, role: String = "AXButton") -> ElementRef {
    .ax(path: [0], role: role, label: label)
  }

  // MARK: - The closed set stays closed

  /// **`irreversibleKinds` is a mirror, and a mirror that drifts is worse than
  /// no mirror.** It exists so a human reviewing `Constants.swift` sees the
  /// gated list without reading the enum; `drag` joining the set has to appear
  /// in both places or the review surface lies.
  @Test("the irreversible mirror still matches the enum after the additions")
  func mirrorHolds() {
    let fromEnum = Set(
      ActionKind.allCases.filter(\.isIrreversibleByDefault).map(\.rawValue))
    #expect(fromEnum == Constants.Safety.irreversibleKinds)
    #expect(fromEnum.contains("drag"))
  }

  @Test("the new discrete verbs are reversible by default")
  func discreteVerbsAreReversible() {
    for kind in [ActionKind.doubleClick, .rightClick, .hover, .setValue] {
      #expect(kind.isIrreversibleByDefault == false, "\(kind.rawValue) is reversible")
    }
  }

  /// **A drag is irreversible by default, unlike every other pointer verb.**
  /// A click that lands wrong selects the wrong thing; a drag that lands wrong
  /// has already moved something, and the place it came from is not recorded
  /// anywhere the agent can read back. Dropping a file on Trash is a `delete`
  /// wearing a different verb.
  @Test("drag is irreversible by default")
  func dragIsIrreversible() {
    #expect(ActionKind.drag.isIrreversibleByDefault)
  }

  // MARK: - Targets

  @Test("the new pointer verbs all require a target")
  func pointerVerbsNeedTargets() {
    for kind in [ActionKind.doubleClick, .rightClick, .hover, .setValue, .drag] {
      #expect(PlanStep.needsTarget(kind), "\(kind.rawValue) names an element")
    }
  }

  /// Only `drag` carries a second endpoint, and it is required. An action that
  /// says "move this" without saying where cannot be executed OR confirmed.
  @Test("drag is the only kind that needs a destination")
  func onlyDragNeedsDestination() {
    for kind in ActionKind.allCases {
      #expect(
        Action.needsDestination(kind) == (kind == .drag),
        "\(kind.rawValue)")
    }
  }

  @Test("a drag names both ends in its summary")
  func dragSummaryNamesBothEnds() {
    let action = Action(
      kind: .drag, target: Self.ax("report.pdf"), destination: Self.ax("Archive"),
      payload: nil, rationale: "file it")
    #expect(action.summary.contains("report.pdf"))
    #expect(action.summary.contains("Archive"))
  }

  /// A confirmation that says "drag report.pdf" and not where to is a
  /// confirmation of half the action.
  @Test("setValue reports the value it will write")
  func setValueSummaryNamesValue() {
    let action = Action(
      kind: .setValue, target: Self.ax("Zoom", role: "AXSlider"),
      payload: "150", rationale: "zoom in")
    #expect(action.summary.contains("Zoom"))
    #expect(action.summary.contains("150"))
  }
}

/// How the new verbs pass through the deterministic gate.
@Suite("New actions — the safety gate")
struct NewActionSafetyTests {

  static func ax(_ label: String, role: String = "AXButton") -> ElementRef {
    .ax(path: [0], role: role, label: label)
  }

  static func element(_ label: String, role: String = "AXButton") -> Element {
    Element(
      ref: Self.ax(label, role: role), role: role, label: label, enabled: true,
      inViewport: true, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
  }

  /// **The destination is a sixth input to `classify`, and it is the one that
  /// matters for a drag.** The thing being dragged is innocent — a file, a
  /// card, a row. What makes the action destructive is *where it lands*, and
  /// before this the classifier could not see that at all.
  @Test("a drag onto a denylisted destination is irreversible")
  func dragOntoTrashIsIrreversible() {
    let action = Action(
      kind: .drag, target: Self.ax("report.pdf"), destination: Self.ax("Trash"),
      payload: nil, rationale: "tidy up")
    let effective = Irreversibility.classify(
      action, target: Self.element("report.pdf"), destination: Self.element("Trash"))
    #expect(effective == .irreversible)
  }

  /// Upgrade-only holds for the new input too: a harmless destination cannot
  /// talk a drag *down* out of the irreversible default its kind carries.
  @Test("a harmless destination cannot downgrade a drag")
  func destinationCannotDowngrade() {
    let action = Action(
      kind: .drag, target: Self.ax("report.pdf"), destination: Self.ax("Archive"),
      payload: nil, rationale: "file it")
    let effective = Irreversibility.classify(
      action, target: Self.element("report.pdf"), destination: Self.element("Archive"))
    #expect(effective == .irreversible, "drag's own default still stands")
  }

  /// The destination reaches the denylist for *reversible* kinds too, so the
  /// input is not dead weight the moment a future verb needs it.
  @Test("a denylisted destination raises an otherwise reversible action")
  func destinationRaisesReversibleKinds() {
    let action = Action(
      kind: .hover, target: Self.ax("row"), destination: Self.ax("Delete account"),
      payload: nil, rationale: "peek")
    let effective = Irreversibility.classify(
      action, target: Self.element("row"), destination: Self.element("Delete account"))
    #expect(effective == .irreversible)
  }

  /// `hover` and `doubleClick` are ordinary pointer verbs: they inherit the
  /// denylist through the element they name, exactly as `click` does, and
  /// nothing about being new makes them special.
  @Test("a new pointer verb on a denylisted label is still gated")
  func newVerbsInheritTheDenylist() {
    for kind in [ActionKind.doubleClick, .rightClick, .hover] {
      let action = Action(
        kind: kind, target: Self.ax("Delete"), payload: nil, rationale: "x")
      let effective = Irreversibility.classify(action, target: Self.element("Delete"))
      #expect(effective == .irreversible, "\(kind.rawValue) on Delete")
    }
  }

  @Test("a new pointer verb on an ordinary label stays reversible")
  func newVerbsOnOrdinaryLabels() {
    for kind in [ActionKind.doubleClick, .rightClick, .hover, .setValue] {
      let action = Action(
        kind: kind, target: Self.ax("Zoom"), payload: "150", rationale: "x")
      let effective = Irreversibility.classify(action, target: Self.element("Zoom"))
      #expect(effective == .reversible, "\(kind.rawValue) on Zoom")
    }
  }
}

/// The widened key vocabulary.
@Suite("Key vocabulary")
struct KeyVocabularyTests {

  /// The original three are load-bearing and must not move.
  @Test("enter, tab and escape survive the widening")
  func originalKeysIntact() {
    #expect(Key(rawValue: "enter") == .enter)
    #expect(Key(rawValue: "tab") == .tab)
    #expect(Key(rawValue: "escape") == .escape)
  }

  @Test("navigation and editing keys parse")
  func newKeysParse() {
    for raw in [
      "up", "down", "left", "right", "home", "end", "pageUp", "pageDown",
      "backspace", "forwardDelete", "space", "selectAll", "undo",
    ] {
      #expect(Key(rawValue: raw) != nil, "\(raw) must parse")
    }
  }

  /// **Clipboard verbs are deliberately absent.** `copy` and `paste` move
  /// content the confirmation sheet cannot display: a gated action whose payload
  /// is invisible breaks the one property every other action holds, which is
  /// that a human sees exactly what is about to happen. `type` already covers
  /// text entry, and its payload is shown verbatim.
  @Test("clipboard keys are not in the vocabulary")
  func noClipboardKeys() {
    #expect(Key(rawValue: "paste") == nil)
    #expect(Key(rawValue: "copy") == nil)
    #expect(Key(rawValue: "cut") == nil)
  }

  /// `enter` remains the only key routed through the submit-label denylist.
  /// Widening the vocabulary must not widen what is gated — an arrow key
  /// activates nothing, and gating it would teach people the sheet is noise.
  @Test("widening the vocabulary did not widen the gated set")
  func gatedSetUnchanged() {
    #expect(Constants.Safety.gatedKeys == ["enter"])
  }

  /// Every key in the vocabulary must be synthesizable, or a plan can name a
  /// key that parses and then fails at the executor — which is a defect that
  /// only shows up mid-run, on someone's screen.
  @Test("every key in the enum has a keycode")
  func everyKeyIsSynthesizable() {
    for key in Key.allCases {
      #expect(KeySynthesis.canSynthesize(key), "\(key.rawValue) has no keycode")
    }
  }
}

/// What a control ended up holding, and how close is close enough.
///
/// The first version compared `abs(wanted - got) < 0.5` in two files. That is
/// reasonable for a 0–100 volume slider and nonsense for a 0–1 range input,
/// where the whole scale is 1.0 — so a write of 0.2 that landed on 0.6 passed.
@Suite("Value read-back")
struct ValueReadbackTests {

  @Test("a control that reports no value is not evidence of failure")
  func silentControlPasses() throws {
    try ValueReadback.verify(wrote: "73", read: nil, numeric: true)
  }

  @Test("an exact numeric landing passes")
  func exactPasses() throws {
    try ValueReadback.verify(
      wrote: "73", read: "73", range: (0, 100), numeric: true)
  }

  /// **The regression.** On a 0–1 range the tolerance must scale with the
  /// range, or two thirds of the scale reads as agreement.
  @Test("a 0-1 slider that clamps to the wrong end fails")
  func normalisedRangeCatchesClamp() {
    #expect(throws: ValueReadback.Mismatch.self) {
      try ValueReadback.verify(
        wrote: "0.2", read: "0.6", range: (0, 1), numeric: true)
    }
  }

  @Test("a 0-100 slider still tolerates a rounding step")
  func wideRangeToleratesRounding() throws {
    try ValueReadback.verify(
      wrote: "73", read: "73.4", range: (0, 100), numeric: true)
  }

  @Test("a clamped 0-100 slider still fails")
  func wideRangeCatchesClamp() {
    #expect(throws: ValueReadback.Mismatch.self) {
      try ValueReadback.verify(
        wrote: "150", read: "100", range: (0, 100), numeric: true)
    }
  }

  /// **`"007"` is not the number seven.** Coercing on "does the string parse as
  /// a number" wrote 7 into a text field and then compared numerically and
  /// agreed with itself — a wrong value reported as a right one. Whether the
  /// control holds a number is the control's business, not the string's.
  @Test("a text control compares exactly, leading zeros and all")
  func textComparesExactly() {
    #expect(throws: ValueReadback.Mismatch.self) {
      try ValueReadback.verify(wrote: "007", read: "7", numeric: false)
    }
  }

  @Test("text that matches exactly passes")
  func textExactPasses() throws {
    try ValueReadback.verify(wrote: "007", read: "007", numeric: false)
  }

  /// With no range to scale against, half a unit — enough for a stepper that
  /// rounds to integers, which is what a control with no published bounds
  /// usually is.
  @Test("an unknown range falls back to an absolute tolerance")
  func unknownRangeFallback() throws {
    try ValueReadback.verify(wrote: "73", read: "73.2", numeric: true)
    #expect(throws: ValueReadback.Mismatch.self) {
      try ValueReadback.verify(wrote: "73", read: "80", numeric: true)
    }
  }
}
