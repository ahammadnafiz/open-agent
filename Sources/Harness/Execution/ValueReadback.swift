import Foundation

/// Whether a control ended up holding what was written to it.
///
/// **A write that reports success and did not take is the failure this exists
/// to catch.** `AXUIElementSetAttributeValue` returns `.success` for a value the
/// control then clamps, rounds or ignores outright, and a DOM assignment a
/// framework reverts looks identical from outside. Reporting `dispatched: true`
/// on either is the same lie `type` already learned not to tell — and the next
/// step inherits it, because the screen no longer matches the plan.
///
/// Shared by both tiers on purpose. The comparison was written twice, once in
/// `AXExecutor` and once in `BiDiExecutor`, and two copies of a tolerance is a
/// tolerance that drifts.
enum ValueReadback {

  /// How close a numeric read-back has to be, as a fraction of the control's
  /// own range.
  ///
  /// **Relative, because an absolute tolerance is meaningless across controls.**
  /// The first version compared `abs(wanted - got) < 0.5`, which is reasonable
  /// for a 0–100 volume slider and nonsense for `<input type="range" min="0"
  /// max="1">`, where the entire range is 1.0: writing 0.2, landing on 0.6, and
  /// passing. macOS sliders report normalised 0…1 just as often as they report
  /// a domain range.
  static let rangeTolerance = 0.005

  /// Absolute fallback when the control will not say what its range is.
  ///
  /// Half a unit — enough to survive a stepper rounding to integers, which is
  /// the common case for a control that exposes no bounds.
  static let unknownRangeTolerance = 0.5

  enum Mismatch: Error, Equatable {
    case settled(wanted: String, got: String)
  }

  /// - Parameters:
  ///   - wrote: the value asked for, as the plan wrote it.
  ///   - read: what the control reports now. `nil` means the control exposes no
  ///     value at all, which is **not** evidence of failure — the same rule
  ///     `type` uses — so it passes.
  ///   - range: the control's own bounds, when it publishes them.
  ///   - numeric: whether the control actually stores a number. A text field
  ///     holding `"007"` is not the number 7, and comparing it numerically is
  ///     how a wrong value gets reported as a right one.
  static func verify(
    wrote: String, read: String?, range: (min: Double, max: Double)? = nil, numeric: Bool
  ) throws {
    guard let read else { return }

    guard numeric, let wanted = Double(wrote), let got = Double(read) else {
      // Text compares exactly. Leading zeros, units and formatting are all
      // part of what was asked for.
      guard read == wrote else { throw Mismatch.settled(wanted: wrote, got: read) }
      return
    }

    let tolerance =
      if let range, range.max > range.min {
        (range.max - range.min) * rangeTolerance
      } else {
        unknownRangeTolerance
      }
    guard abs(wanted - got) <= tolerance else {
      throw Mismatch.settled(wanted: wrote, got: read)
    }
  }

  /// The sentence a human reads when a control refused a value.
  static func describe(_ mismatch: Mismatch) -> String {
    switch mismatch {
    case .settled(let wanted, let got):
      "\(wanted) (the control settled at \(got))"
    }
  }
}
