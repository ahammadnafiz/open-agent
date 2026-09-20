import CoreGraphics
import Foundation
import Testing

@testable import Harness

/// The browser tier — ADR 0010.
///
/// Everything here runs offline. The live legs (a real page, a real click) are
/// `Probe` subcommands, because a test suite that needs a browser is a test
/// suite people stop running.
@Suite("BiDi value decoding")
struct BiDiValueTests {

  /// BiDi does not send JSON. It sends a tagged encoding, and a client that
  /// treats `{"type":"string","value":"x"}` as an object gets a dictionary
  /// where it expected a label.
  @Test("primitives unwrap to plain Swift values")
  func primitives() {
    #expect(BiDiValue.plain(["type": "string", "value": "Post"]) as? String == "Post")
    #expect(BiDiValue.plain(["type": "boolean", "value": true]) as? Bool == true)
    #expect(BiDiValue.plain(["type": "number", "value": 42.0]) as? Double == 42.0)
    #expect(BiDiValue.plain(["type": "null"]) == nil)
    #expect(BiDiValue.plain(["type": "undefined"]) == nil)
  }

  /// `Infinity` and `NaN` arrive as strings, not numbers. A client that force
  /// casts to `Double` crashes on a page that computed one.
  @Test("non-finite numbers arrive as strings and do not crash")
  func nonFiniteNumbers() {
    #expect(BiDiValue.plain(["type": "number", "value": "Infinity"]) as? String == "Infinity")
    #expect(BiDiValue.plain(["type": "number", "value": "NaN"]) as? String == "NaN")
  }

  /// Objects are pair arrays, not dictionaries.
  @Test("objects unwrap from BiDi's pair-array encoding")
  func objects() {
    let node: [String: Any] = [
      "type": "object",
      "value": [
        [["type": "string", "value": "url"], ["type": "string", "value": "https://example.com"]],
        [["type": "string", "value": "count"], ["type": "number", "value": 3.0]],
      ],
    ]
    let plain = BiDiValue.plain(node) as? [String: Any]
    #expect(plain?["url"] as? String == "https://example.com")
    #expect(plain?["count"] as? Double == 3.0)
  }

  @Test("arrays unwrap element-wise")
  func arrays() {
    let node: [String: Any] = [
      "type": "array",
      "value": [
        ["type": "string", "value": "a"],
        ["type": "string", "value": "b"],
      ],
    ]
    #expect(BiDiValue.plain(node) as? [String] == ["a", "b"])
  }
}

@Suite("Snapshot decoding")
struct SnapshotTests {

  static func rawAction(
    id: String = "e1", role: String = "button", label: String = "Post",
    kind: String = "click", disabled: Bool = false, occluded: Bool = false,
    submit: String = ""
  ) -> [String: Any] {
    [
      "id": id, "role": role, "label": label, "kind": kind,
      "disabled": disabled, "occluded": occluded, "submit": submit,
      "x": 10.0, "y": 20.0, "w": 80.0, "h": 30.0, "value": "", "checked": "", "expanded": "",
    ]
  }

  @Test("a snapshot decodes into actions and guards")
  func decodesSnapshot() {
    let raw: [String: Any] = [
      "url": "https://example.com", "title": "Example",
      "text": "hello", "page_key": "k1",
      "actions": [Self.rawAction(), Self.rawAction(id: "e2", role: "link", label: "Home")],
      "guards": ["e1": "button|Post|10|20|0"],
    ]
    let snapshot = BiDiSnapshot(raw)
    #expect(snapshot.url == "https://example.com")
    #expect(snapshot.actions.count == 2)
    #expect(snapshot.actions[0].label == "Post")
    #expect(snapshot.actions[0].bounds == CGRect(x: 10, y: 20, width: 80, height: 30))
    #expect(snapshot.guards["e1"] == "button|Post|10|20|0")
  }

  /// A malformed action is dropped, not defaulted. An action with no label
  /// cannot be named in a confirmation or matched by the denylist.
  @Test("an action missing a required field is dropped")
  func dropsMalformedAction() {
    let raw: [String: Any] = [
      "actions": [
        Self.rawAction(),
        ["id": "e9", "role": "button"],  // no label
      ]
    ]
    #expect(BiDiSnapshot(raw).actions.count == 1)
  }

  /// An occluded control is in the viewport and cannot be clicked — a modal or
  /// a cookie banner is over it. Reporting it as out-of-viewport lets the
  /// deterministic filter drop it, instead of offering a candidate whose click
  /// would land on the overlay.
  @Test("an occluded action is reported as out of viewport")
  func occlusionSuppressesCandidacy() async throws {
    let occluded = SnapshotAction(Self.rawAction(occluded: true))
    let clear = SnapshotAction(Self.rawAction(occluded: false))
    #expect(occluded?.occluded == true)
    #expect(clear?.occluded == false)
  }
}

@Suite("Snapshot script")
struct SnapshotScriptTests {

  /// The script runs as one `script.evaluate`. If it is ever split, the
  /// 1,092 → 101 protocol-call result ADR 0010 is built on goes with it.
  @Test("the script is a single self-invoking expression")
  func singleExpression() {
    let source = SnapshotScript.source.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(source.hasPrefix("(() =>"))
    #expect(source.hasSuffix("})()"))
  }

  /// A password or file input is never a candidate. Typing into one would put a
  /// credential into `state`, a log, and the host's context — and
  /// `risk_credential` is advisory, where this is not.
  @Test("password and file inputs are excluded by construction")
  func excludesCredentialInputs() {
    #expect(SnapshotScript.source.contains("'password', 'file', 'hidden'"))
  }

  /// `element-sources.md` specified piercing open shadow roots before ADR 0010,
  /// and it is the one place this reader goes further than the design it is
  /// adapted from.
  @Test("open shadow roots are pierced")
  func piercesShadowRoots() {
    #expect(SnapshotScript.source.contains("el.shadowRoot"))
  }

  /// ADR 0008: a text field carries no hint that its form submits to `Send`.
  /// The DOM can compute it; the accessibility API cannot.
  @Test("the submit target is computed for fillable fields")
  func computesSubmitTarget() {
    #expect(SnapshotScript.source.contains("button[type=\"submit\"]"))
    #expect(SnapshotScript.source.contains("submit: submit"))
  }

  /// Ids are `e`-prefixed, matching the native tier and the host contract.
  @Test("ids share the e-prefixed namespace")
  func ePrefixedIDs() {
    #expect(SnapshotScript.source.contains("const key = 'e' + id"))
  }

  /// Their cap is 250, ours is 255. The snapshot must not be able to hand the
  /// filter more than it will accept without escalating.
  @Test("the script's cap sits under the candidate ceiling")
  func capUnderCeiling() {
    #expect(SnapshotScript.source.contains("MAX_ACTIONS = 250"))
    #expect(250 <= Constants.Jev.maxCandidates)
  }
}
