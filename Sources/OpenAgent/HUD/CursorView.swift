import SwiftUI

/// What the agent is about to do, expressed as colour.
///
/// Two states only. A third would be decoration: the user needs to know whether
/// this action is the kind that gets confirmed, and nothing finer than that.
public enum CursorIntent: Sendable {
  case routine
  case irreversible

  var tint: Color {
    switch self {
    case .routine: Color(red: 0.24, green: 0.54, blue: 1.00)
    case .irreversible: Color(red: 1.00, green: 0.62, blue: 0.16)
    }
  }
}

/// Everything the overlay draws. Mutated only on the main actor, only by
/// `CursorOverlay`, and read by SwiftUI.
///
/// **Every geometry value here is view-local AppKit space** — origin bottom-left,
/// converted once at the boundary in `CursorOverlay`. Nothing downstream of that
/// conversion deals in two coordinate systems, because code that does eventually
/// gets one of them wrong.
@MainActor
@Observable
final class OverlayState {
  var cursor: CGPoint = .zero
  var target: CGRect?
  var verb: String = ""
  var label: String = ""
  var intent: CursorIntent = .routine
  var isVisible = false
  var isPressing = false
  var clickCount = 0
  /// False on `.captured` steps.
  ///
  /// `CapturedExecutor` posts a real `CGEvent`, which moves the user's actual
  /// pointer. Tiers 1–2 move no pointer at all — they dispatch to the element.
  /// So on a captured step both the drawn cursor and the system arrow arrive at
  /// the same place, which reads as a rendering glitch on precisely the step
  /// where the least familiar thing is happening.
  ///
  /// The ring and the narration chip stay: the real pointer is genuinely doing
  /// the work, and saying so is more honest than drawing a second arrow over it.
  /// Open Question Q9 — this needs watching on a real terminal or canvas before
  /// it is believed.
  var showsCursor = true

  /// Degrees the arrow banks into its travel, positive clockwise.
  ///
  /// Apple's guidance is to hint in the direction of the gesture — humans
  /// predict a final state from a trajectory, so the in-between frames should
  /// point at the outcome rather than merely interpolate toward it. Set from
  /// the heading in `CursorOverlay.move`, and returned to zero on arrival so
  /// the pointer reads as settled rather than permanently tilted.
  var lean: Double = 0

  /// Where the trailing dot is, which is not where the cursor is.
  ///
  /// Driven to the same destination on a slower spring, so the gap between them
  /// opens while travelling and closes on arrival. That gap is how speed is
  /// drawn — with a shape, not a gradient.
  var companion: CGPoint = .zero
}

// MARK: - The cursor itself

/// The arrow, drawn as flat geometry.
///
/// **No gradients, no blur, no glow.** Apple's own pointer is a flat white fill
/// with a hard dark outline, and the reason is not taste: this thing is drawn
/// over *every* application, so it has to stay legible on a white page, a black
/// terminal and a photograph without knowing which it is on. A blurred halo
/// solves that by smearing luminance, which reads as a rendering artefact —
/// software that looks broken rather than deliberate. A hard outline solves it
/// with a shape.
///
/// Every coordinate below is on a 12-unit grid so the silhouette holds at any
/// size. The proportions are the system arrow's, because familiarity is the
/// point: people already know what this shape means, and an agent that invents
/// its own pointer spends the user's attention teaching them a new one.
private struct ArrowGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let s = rect.width / 12.0
    var p = Path()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: 0, y: 16.5 * s))
    p.addLine(to: CGPoint(x: 4.2 * s, y: 12.7 * s))
    p.addLine(to: CGPoint(x: 6.7 * s, y: 18.3 * s))
    p.addLine(to: CGPoint(x: 9.3 * s, y: 17.2 * s))
    p.addLine(to: CGPoint(x: 6.9 * s, y: 11.7 * s))
    p.addLine(to: CGPoint(x: 11.6 * s, y: 11.3 * s))
    p.closeSubpath()
    return p
  }
}

/// The agent's pointer, and the dot that follows it.
///
/// The arrow is the system arrow: flat white, hard dark outline, nothing else.
/// People already know what that shape means, and an agent that invents its own
/// pointer spends the user's attention teaching them a new one. It stays the
/// same on a white page, a black terminal and a photograph, because the outline
/// is a shape rather than a luminance trick.
///
/// **The dot is the whole idea.** It is one flat circle in the intent colour,
/// and it trails the arrow on a slower spring — so when the pointer sets off
/// the dot is behind it, and when the pointer stops the dot catches up and
/// settles. Nothing is drawn to represent motion; the motion *is* the
/// difference between two springs.
///
/// It earns its place three times over, which is the test for whether an
/// element should exist at all:
///
/// - It says whose cursor this is, instantly and without a legend.
/// - It carries the intent colour, so an irreversible step is legible before
///   you have read the chip.
/// - Its lag encodes speed. A long sweep stretches the gap; a short hop barely
///   opens it. That is the same information a motion blur carries, drawn with a
///   shape instead of a gradient.
private struct AgentCursor: View {
  let intent: CursorIntent
  let isPressing: Bool
  /// Degrees, positive clockwise. Set from the direction of travel.
  let lean: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ArrowGlyph()
      .fill(.white)
      .overlay(ArrowGlyph().stroke(Color(white: 0.08), lineWidth: 1.4))
      .frame(width: 19, height: 29)
      // A hairline shadow, not a glow: enough to separate the outline from a
      // background that happens to be the same near-black, and no more.
      .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)
      .rotationEffect(.degrees(reduceMotion ? 0 : lean), anchor: .topLeading)
      .scaleEffect(isPressing ? 0.86 : 1.0, anchor: .topLeading)
      .animation(
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.28),
        value: lean
      )
      .animation(
        reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.18, bounce: 0.34),
        value: isPressing
      )
  }
}

/// The trailing dot. Drawn beneath the arrow, at its own position.
private struct CompanionDot: View {
  let intent: CursorIntent
  let isPressing: Bool

  var body: some View {
    Circle()
      .fill(intent.tint)
      .frame(width: 7, height: 7)
      // Squashes on the press, so the dot reacts to the click rather than
      // sitting through it. Feedback belongs on the causal event.
      .scaleEffect(isPressing ? 1.5 : 1.0)
      .animation(.spring(duration: 0.22, bounce: 0.4), value: isPressing)
  }
}

// MARK: - Target highlight

/// Drawn on the element **before** the cursor arrives. The anticipation is the
/// point: it gives the user time to see where this is going and object, which a
/// confirmation dialog appearing at the last moment does not.
private struct TargetRing: View {
  let rect: CGRect
  let intent: CursorIntent

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .strokeBorder(intent.tint, lineWidth: 1.5)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(intent.tint.opacity(0.10))
      )
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      // Sized to the element, so the glow stays proportional instead of
      // swamping a small control and vanishing on a large one.
      .shadow(color: intent.tint.opacity(0.45), radius: min(rect.height * 0.4, 10))
  }
}

// MARK: - Narration

/// "Click · Send". The agent has no interface of its own, so this is the only
/// place it says what it is doing while it does it.
private struct NarrationChip: View {
  let verb: String
  let label: String
  let intent: CursorIntent

  var body: some View {
    HStack(spacing: 6) {
      // Small text wants slightly POSITIVE tracking — letters read too close
      // together as they shrink. The inverse of what large display text needs,
      // and a single letter-spacing value for both is wrong somewhere.
      Text(verb.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(intent.tint)

      if !label.isEmpty {
        Text(label)
          .font(.system(size: 12, weight: .medium))
          .tracking(0.1)
          // Slightly heavier than body weight, because flat text over a
          // blurred surface loses contrast against whatever is behind it.
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 260, alignment: .leading)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
    // A bright hairline is light catching the material — the cue that makes a
    // translucent surface read as a real one rather than a tinted rectangle.
    // A flat stroke, not a gradient: the whole overlay is drawn from solid
    // shapes, and one gradient in the set is the thing that looks out of place.
    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    .fixedSize()
  }
}

// MARK: - Click feedback

private struct ClickRipple: View {
  let intent: CursorIntent
  @State private var expanded = false

  var body: some View {
    Circle()
      .stroke(intent.tint, lineWidth: 2)
      .frame(width: 22, height: 22)
      .scaleEffect(expanded ? 2.6 : 0.4)
      .opacity(expanded ? 0 : 0.9)
      .onAppear {
        withAnimation(.easeOut(duration: 0.45)) { expanded = true }
      }
  }
}

// MARK: - Composition

struct CursorOverlayView: View {
  @Bindable var state: OverlayState

  /// Flips the chip to the left of the cursor near a screen edge, so the
  /// narration never runs off the display it is describing.
  private func chipOffset(in size: CGSize) -> CGSize {
    // Clear of the arrow, which is 29pt tall measured from its tip. At the old
    // 26pt the chip crossed the glyph and the pointer read as being behind a
    // label.
    let nearRight = state.cursor.x > size.width - 260
    return CGSize(width: nearRight ? -24 : 30, height: 40)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        if let t = state.target {
          TargetRing(rect: t, intent: state.intent)
            .transition(.opacity.combined(with: .scale(scale: 1.08)))
        }

        ClickRipple(intent: state.intent)
          .id(state.clickCount)
          .position(state.cursor)
          .opacity(state.clickCount == 0 ? 0 : 1)
          .allowsHitTesting(false)

        if state.showsCursor {
          // Beneath the arrow, so the arrow's tip — the thing that says exactly
          // where the click lands — is never obscured by its own companion.
          CompanionDot(intent: state.intent, isPressing: state.isPressing)
            .position(state.companion)
        }

        NarrationChip(verb: state.verb, label: state.label, intent: state.intent)
          .position(state.cursor)
          .offset(chipOffset(in: geo.size))
          .opacity(state.verb.isEmpty ? 0 : 1)

        // Drawn last, so nothing can cover it. The arrow's tip is the only
        // thing on screen that says exactly where the click will land, and a
        // label sitting on top of it is worse than no label — it is the overlay
        // obscuring the one fact it exists to communicate.
        if state.showsCursor {
          AgentCursor(intent: state.intent, isPressing: state.isPressing, lean: state.lean)
            .position(state.cursor)
        }
      }
      .opacity(state.isVisible ? 1 : 0)
      .animation(.easeInOut(duration: 0.2), value: state.isVisible)
    }
    .ignoresSafeArea()
  }
}
