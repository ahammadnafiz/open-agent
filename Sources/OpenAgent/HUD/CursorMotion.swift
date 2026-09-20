import AppKit
import Foundation
import Harness

/// Drives the pointer frame by frame, on the display's own clock.
///
/// **Why not `withAnimation`.** Handing a position to the animation system
/// means the pointer is *interpolated* between two values — it travels in a
/// straight line, at whatever curve the system picks, and anything else you
/// want it to do has to be layered on top as a second animation that can drift
/// out of phase with the first. Driving it here means one function owns where
/// the pointer is at time `t`, which is what makes an arc, a hand's drift and a
/// settle compose instead of fight.
///
/// It also removes a class of latency. A display link fires in step with the
/// panel's actual refresh — 120 Hz on this hardware — so every frame the
/// compositor draws has a position computed for it. Nothing is ever showing a
/// value from the previous frame because the animation system had not got round
/// to it yet.
@MainActor
final class CursorMotion {

  /// Where the pointer is, and what is carrying it there.
  private struct Flight {
    let from: CGPoint
    let to: CGPoint
    /// Perpendicular bow, in points, at the midpoint.
    let bow: CGFloat
    let duration: Double
    let started: CFTimeInterval
  }

  private var link: CADisplayLink?
  private var flight: Flight?
  private var settled: CGPoint = .zero
  private var onFrame: ((CGPoint, CGFloat) -> Void)?
  private var completion: (() -> Void)?

  /// Seconds since the engine started, used to phase the idle drift.
  private var clock: CFTimeInterval = 0

  // MARK: - Lifecycle

  /// Starts the display link against the view that will draw the result, so it
  /// ticks at that screen's refresh rate rather than a guessed interval.
  func attach(to view: NSView, onFrame: @escaping (CGPoint, CGFloat) -> Void) {
    self.onFrame = onFrame
    guard link == nil else { return }
    let link = view.displayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func detach() {
    link?.invalidate()
    link = nil
  }

  func place(at point: CGPoint) {
    settled = point
    flight = nil
  }

  // MARK: - Flight

  /// Sends the pointer to `destination`, arriving in `duration` seconds.
  ///
  /// The path bows perpendicular to the direction of travel. A hand moving
  /// between two points does not travel in a straight line — the arm pivots at
  /// the shoulder and elbow, so the path is an arc, and the longer the reach
  /// the more pronounced it is. A pointer that travels on a ruled line reads as
  /// a machine drawing a line, which is exactly what it is and exactly what
  /// this is trying not to look like.
  func fly(to destination: CGPoint, duration: Double, completion: @escaping () -> Void) {
    let from = settled
    let dx = destination.x - from.x
    let dy = destination.y - from.y
    let distance = (dx * dx + dy * dy).squareRoot()

    // Proportional to reach, capped: a long sweep across two monitors should
    // not describe a semicircle. Signed by travel direction so consecutive
    // moves in the same direction bow the same way and the path reads as one
    // continuous gesture rather than a zigzag.
    let bow = min(distance * Self.bowFraction, Self.maxBow) * (dx >= 0 ? 1 : -1)

    flight = Flight(
      from: from, to: destination, bow: bow,
      duration: max(duration, 0.001), started: CACurrentMediaTime()
    )
    self.completion = completion
  }

  // MARK: - The frame

  @objc private func tick(_ sender: CADisplayLink) {
    clock = CACurrentMediaTime()

    var position = settled
    var progress: CGFloat = 1

    if let flight {
      let elapsed = clock - flight.started
      let t = min(max(elapsed / flight.duration, 0), 1)
      progress = CGFloat(t)

      // Critically-damped-looking ease. The pointer must not overshoot the
      // element it is about to click — an arrival that springs past the target
      // and comes back reads as imprecision on the one gesture where precision
      // is the entire point.
      let eased = Self.easeOutQuint(t)

      let x = flight.from.x + (flight.to.x - flight.from.x) * eased
      let y = flight.from.y + (flight.to.y - flight.from.y) * eased

      // The bow peaks at the midpoint and is gone by arrival, so the pointer
      // lands exactly on its target rather than near it.
      let arc = sin(Double.pi * eased) * flight.bow
      let dx = flight.to.x - flight.from.x
      let dy = flight.to.y - flight.from.y
      let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
      // Perpendicular to the direction of travel.
      position = CGPoint(x: x + (-dy / length) * arc, y: y + (dx / length) * arc)

      if t >= 1 {
        settled = flight.to
        self.flight = nil
        let done = completion
        completion = nil
        done?()
      }
    }

    onFrame?(CGPoint(x: position.x + drift.width, y: position.y + drift.height), progress)
  }

  /// The tremor of a hand that is holding still.
  ///
  /// A hand resting on a mouse is never actually still — it drifts a pixel or
  /// two, continuously and without a pattern you can name. A pointer frozen to
  /// an exact coordinate between steps is the single clearest tell that nobody
  /// is holding it, and the overlay exists to make the agent's work legible as
  /// *work* rather than as windows changing by themselves.
  ///
  /// Two sines at frequencies with no common multiple, so the path never
  /// visibly repeats. Amplitude is deliberately under the size of the arrow's
  /// own outline: it should read as aliveness, never as the pointer being
  /// unsure where it is.
  private var drift: CGSize {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .zero }
    let x = sin(clock * 0.9) * 0.6 + sin(clock * 2.3) * 0.35
    let y = cos(clock * 1.1) * 0.55 + cos(clock * 2.9) * 0.3
    return CGSize(width: x, height: y)
  }

  // MARK: - Constants
  //
  // These are shape, not policy: they describe what the motion looks like
  // rather than deciding anything the agent does, which is why they live beside
  // the code that draws them rather than in the file a human reviews before a
  // release.

  /// How far the path bows, as a fraction of the distance travelled.
  private static let bowFraction: CGFloat = 0.11
  /// Ceiling on the bow, so a cross-screen sweep stays a reach and not an arc.
  private static let maxBow: CGFloat = 46

  /// Quintic ease-out: fast departure, long settle, no overshoot.
  private static func easeOutQuint(_ t: Double) -> Double {
    1 - pow(1 - t, 5)
  }
}
