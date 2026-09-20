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
}

// MARK: - The cursor itself

/// The macOS arrow, drawn rather than screenshotted so it stays crisp at any
/// scale and can be tinted.
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

private struct AgentCursor: View {
  let intent: CursorIntent
  let isPressing: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      // A tinted halo is what separates the agent's pointer from the
      // user's own. The arrow stays white so it still reads as a cursor.
      Circle()
        .fill(intent.tint.opacity(0.28))
        .frame(width: 34, height: 34)
        .blur(radius: 7)
        .offset(x: -11, y: -10)

      ArrowGlyph()
        .fill(.white)
        .overlay(ArrowGlyph().stroke(.black.opacity(0.85), lineWidth: 1.1))
        .frame(width: 19, height: 29)
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
    }
    .scaleEffect(isPressing ? 0.86 : 1.0, anchor: .topLeading)
    .animation(.spring(response: 0.18, dampingFraction: 0.55), value: isPressing)
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
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .stroke(intent.tint, lineWidth: 2)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(intent.tint.opacity(0.12))
      )
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .shadow(color: intent.tint.opacity(0.5), radius: 8)
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
      Text(verb.uppercased())
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .tracking(0.6)
        .foregroundStyle(intent.tint)

      if !label.isEmpty {
        Text(label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
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
    let nearRight = state.cursor.x > size.width - 260
    return CGSize(width: nearRight ? -18 : 22, height: 26)
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
          AgentCursor(intent: state.intent, isPressing: state.isPressing)
            .position(state.cursor)
        }

        NarrationChip(verb: state.verb, label: state.label, intent: state.intent)
          .position(state.cursor)
          .offset(chipOffset(in: geo.size))
          .opacity(state.verb.isEmpty ? 0 : 1)
      }
      .opacity(state.isVisible ? 1 : 0)
      .animation(.easeInOut(duration: 0.2), value: state.isVisible)
    }
    .ignoresSafeArea()
  }
}
