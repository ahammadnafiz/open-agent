import AppKit
import Harness
import SwiftUI

/// A synthetic cursor drawn over every application, showing what the agent is
/// about to do a moment before it does it.
///
/// **The one rule, and it is architectural rather than stylistic: this overlay
/// READS a target and never produces one.** It consumes `Element.bounds`, which
/// perception already captures for the candidate filter and for drawing vision
/// marks. Nothing it computes flows back into an `Action`, a plan, a Jev state,
/// or the safety classifier. The moment a cursor position becomes an input to
/// anything, this has stopped being a presentation layer and has become the
/// coordinate-driven design ADR 0003 rejected on measured accuracy.
///
/// It is presentation for a system that otherwise has no interface: the agent
/// acts on real applications, so without this the only visible evidence that
/// anything is happening is other people's windows changing by themselves.
@MainActor
public final class CursorOverlay {

  public static let shared = CursorOverlay()

  private let state = OverlayState()
  private var panel: NSPanel?
  private let motion = CursorMotion()

  /// The application this overlay is narrating, or `nil` for the `overlay`
  /// demo, which narrates nothing and should always draw.
  private var stagePID: pid_t?
  private var activationObserver: NSObjectProtocol?

  /// Multiplies pointer velocity. 1.0 is `Constants.HUD.pixelsPerSecond`.
  ///
  /// Exists so the motion can be judged at half and double speed without a
  /// rebuild — the easing curve is a product decision and product decisions
  /// need to be *watched*, repeatedly, before anyone can have an opinion.
  /// It is an instance property rather than a constant because it is a
  /// debugging affordance, not a tuned value; the shipped value lives in
  /// `Constants.HUD`.
  public var speedScale: Double = 1.0

  /// How far the arrow banks into its travel, in degrees.
  ///
  /// Small on purpose. The arrow's hotspot is its tip, and a tilt large enough
  /// to be obvious is a tilt large enough to make people doubt where the click
  /// will land — the one thing this overlay exists to remove doubt about.
  static let maxLeanDegrees: Double = 9

  /// Honours System Settings > Accessibility > Display > Reduce motion.
  ///
  /// Reduced motion does not mean no feedback — it means a gentler,
  /// non-vestibular equivalent. The ring, the chip and the press all stay,
  /// because they are what tells the user what is about to happen; what goes is
  /// the travel, which is the part that sweeps a large object across the whole
  /// screen.
  ///
  /// This overlay draws over every application the user has open, so a setting
  /// they turned on for the system applies here more than almost anywhere.
  var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private init() {}

  // MARK: - Lifecycle

  /// Follow factor for the trailing dot, applied per frame.
  ///
  /// Per-frame rather than a second spring, because two springs racing the same
  /// destination drift out of phase and the gap stops being a function of speed.
  /// This is the classic smooth-follow: each frame the dot closes a fixed
  /// fraction of the distance, so the gap is exactly proportional to how fast
  /// the pointer is moving and closes to nothing the moment it stops.
  private static let companionFollow: CGFloat = 0.16

  public func show() {
    if panel == nil { build() }
    state.isVisible = true
    syncVisibility()
  }

  public func hide() {
    state.isVisible = false
    state.verb = ""
    state.target = nil
    panel?.orderOut(nil)
  }

  // MARK: - The stage

  /// Names the application this overlay is narrating.
  ///
  /// **The overlay is drawn at `.screenSaver` level across the union of every
  /// display, which means it floats above everything the user has open.** That
  /// is right while they are looking at the application the agent is driving
  /// and wrong the instant they are not: the agent works in WhatsApp, the user
  /// switches to Zen, and a cursor appears to press buttons in Zen. Nothing
  /// moved — the overlay simply never knew whose window it was standing in.
  ///
  /// The panel cannot be ordered into another process's window list, so
  /// "appear in the window it is working in" is enforced the only way it can
  /// be: the overlay draws while that application is frontmost and orders
  /// itself out while it is not. The agent keeps working either way. What
  /// stops is the claim that the user can see it happening.
  public func bind(toApplication pid: pid_t) {
    guard stagePID != pid else { return }
    stagePID = pid
    if panel == nil { build() }
    observeActivation()
    syncVisibility()
  }

  /// Whether the narrated application is the one in front of the user.
  ///
  /// An unbound overlay always draws. That is the `overlay` demo, which
  /// narrates no application and would otherwise be invisible.
  static func draws(stage: pid_t?, frontmost: pid_t?) -> Bool {
    guard let stage else { return true }
    return stage == frontmost
  }

  private func observeActivation() {
    guard activationObserver == nil else { return }
    // `NSWorkspace` has its own notification centre; this notification does
    // not arrive on `NotificationCenter.default`. It fires on every app
    // activation, which covers both leaving the stage and returning to it.
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { CursorOverlay.shared.syncVisibility() } }
  }

  private func syncVisibility() {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard state.isVisible, Self.draws(stage: stagePID, frontmost: front) else {
      panel?.orderOut(nil)
      return
    }
    panel?.orderFrontRegardless()
  }

  private func build() {
    let p = NSPanel(
      contentRect: Self.unionFrame,
      // `.nonactivatingPanel` is what keeps the overlay from stealing
      // focus from the application the agent is driving. Without it,
      // showing the cursor changes the very thing it is illustrating.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false

    // Above ordinary windows, below system alerts.
    p.level = .screenSaver

    // Never intercept a click. The overlay sits on top of every target the
    // agent is about to act on, so if it swallowed events it would break
    // exactly the actions it exists to narrate.
    p.ignoresMouseEvents = true

    p.collectionBehavior = [
      .canJoinAllSpaces,  // follow the user across Spaces
      .stationary,  // do not slide during Space transitions
      .fullScreenAuxiliary,  // survive over full-screen apps
      .ignoresCycle,  // never appear in Cmd-` rotation
    ]

    let host = NSHostingView(rootView: CursorOverlayView(state: state))
    p.contentView = host
    panel = p

    // One function owns where the pointer is at time t. Everything the pointer
    // does — travel, arc, drift, the dot's lag — is computed here, on the
    // display's own clock, so nothing can drift out of phase with anything else
    // and no frame is ever drawn from a stale value.
    motion.attach(to: host) { [weak self] point, _ in
      guard let self else { return }
      state.cursor = point
      // Smooth-follow, per frame. The gap is exactly proportional to speed and
      // closes to nothing the moment the pointer stops.
      let anchor = CGPoint(x: point.x + 7, y: point.y + 13)
      state.companion = CGPoint(
        x: state.companion.x + (anchor.x - state.companion.x) * Self.companionFollow,
        y: state.companion.y + (anchor.y - state.companion.y) * Self.companionFollow
      )
    }

    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { CursorOverlay.shared.resize() } }
  }

  private func resize() {
    panel?.setFrame(Self.unionFrame, display: true)
  }

  // MARK: - Coordinate conversion

  /// Every display, in AppKit global space (origin bottom-left, primary at 0,0).
  private static var unionFrame: NSRect {
    NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
  }

  /// Converts a Quartz screen rect — which is what accessibility, screen
  /// capture and `CGEvent` all speak — into the SwiftUI space of the overlay.
  ///
  /// Three coordinate systems meet here and they disagree twice:
  ///   * Quartz / AX / CGEvent: origin at the PRIMARY display's top-left, y DOWN.
  ///   * AppKit `NSScreen.frame`: origin at the primary's bottom-left, y UP.
  ///   * SwiftUI inside the hosting view: origin at the view's top-left, y DOWN.
  ///
  /// Doing this once, at the boundary, is deliberate. Code that carries two
  /// conventions eventually applies the wrong one, and a cursor drawn at the
  /// vertical mirror of its target is a bug that looks like a design problem.
  ///
  /// On a single display this reduces to the identity, which is why it is easy
  /// to get wrong and never notice until a second monitor appears.
  private static func toLocal(_ r: CGRect) -> CGRect {
    let f = unionFrame
    let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
    let quartzTopOfWindow = primaryHeight - f.maxY
    return CGRect(
      x: r.origin.x - f.minX,
      y: r.origin.y - quartzTopOfWindow,
      width: r.width,
      height: r.height
    )
  }

  // MARK: - Motion

  /// Moves the cursor to `bounds` and returns when it has arrived.
  ///
  /// The caller is expected to `await` this and only then execute the action,
  /// which is what buys the user a moment to see the target highlighted and
  /// object before anything happens. That moment is not free: it is
  /// `Constants.HUD` worth of machine time per step, charged against the task
  /// budget like anything else. `Constants.HUD.motionEnabled` turns it off.
  ///
  /// - Parameter bounds: the target's rect in **Quartz screen space**, exactly
  ///   as `Element.bounds` carries it. Converted here and nowhere else.
  /// - Parameter showsCursor: false on `.captured` steps, where the real system
  ///   pointer does the moving and a second drawn arrow would be a glitch.
  ///   The ring and the chip are kept either way — `docs/harness.md` §7.1.
  public func move(
    to bounds: CGRect,
    verb: String,
    label: String,
    intent: CursorIntent = .routine,
    showsCursor: Bool = true
  ) async {
    guard Constants.HUD.motionEnabled else { return }
    show()
    state.showsCursor = showsCursor

    let local = Self.toLocal(bounds)
    let destination = CGPoint(x: local.midX, y: local.midY)
    let distance = hypot(destination.x - state.cursor.x, destination.y - state.cursor.y)

    // Duration scales with distance, the way a real pointer does. A fixed
    // duration makes short hops feel sluggish and long sweeps feel frantic.
    var travel =
      min(
        max(distance / Constants.HUD.pixelsPerSecond, Constants.HUD.minMoveSeconds),
        Constants.HUD.maxMoveSeconds
      ) / speedScale
    // Under reduced motion the cursor crosses the screen almost immediately —
    // the ring and the chip still land first, so the user still sees WHERE
    // before WHAT, without a large object sweeping past them to say it.
    if reduceMotion { travel = 0.05 }

    state.intent = intent
    state.verb = verb
    state.label = label

    // The ring lands first. Anticipation is the whole point of the overlay:
    // the user sees WHERE before they see WHAT.
    //
    // Enter and exit run the same curve in reverse, so the ring leaves the way
    // it arrived. A shape that grows in and fades out reads as two unrelated
    // events rather than one thing appearing and going away.
    withAnimation(
      reduceMotion
        ? .easeOut(duration: 0.12)
        : .spring(duration: Constants.HUD.anticipationSeconds, bounce: 0)
    ) {
      state.target = local
    }
    // The anticipation window is NOT shortened under reduced motion. It is the
    // overlay's entire safety contribution — the time the user has to object —
    // and it is a pause, not a movement.
    try? await Task.sleep(for: .seconds(Constants.HUD.anticipationSeconds))

    // Bank into the turn. Humans predict a final state from a trajectory, so
    // the in-between frames should point at the outcome rather than merely
    // interpolate toward it — the pointer says where it is going while it is
    // still going there.
    //
    // Horizontal component only: a cursor that pitches on vertical travel reads
    // as unstable rather than purposeful.
    let horizontal = destination.x - state.cursor.x
    let lean = max(-Self.maxLeanDegrees, min(Self.maxLeanDegrees, horizontal / 40))

    // The lean is still an animation, because it is a property of the glyph
    // rather than of where the glyph is. Position is not: it is driven.
    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { state.lean = lean }

    // The drawn cursor still travels when it is hidden: the chip and the ripple
    // are positioned from `state.cursor`, so leaving it behind would strand the
    // narration at the previous target.
    await withCheckedContinuation { continuation in
      motion.fly(to: destination, duration: travel) {
        continuation.resume()
      }
    }

    // Level off on arrival, so the pointer reads as settled rather than
    // permanently tilted.
    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { state.lean = 0 }
  }

  /// The press animation. Purely visual — the actual event is dispatched by an
  /// `Executor`, semantically, and usually without any pointer involved at all.
  public func press() async {
    guard Constants.HUD.motionEnabled else { return }
    state.isPressing = true
    state.clickCount += 1
    try? await Task.sleep(for: .seconds(Constants.HUD.pressSeconds))
    state.isPressing = false
    try? await Task.sleep(for: .seconds(Constants.HUD.settleSeconds))
    withAnimation(.spring(duration: Constants.HUD.anticipationSeconds, bounce: 0)) {
      state.target = nil
    }
  }

  /// Narration with no movement — for steps that have no on-screen target,
  /// such as `navigate`, `openApp` and `wait`.
  public func announce(verb: String, label: String) {
    guard Constants.HUD.motionEnabled else { return }
    show()
    state.showsCursor = true
    state.intent = .routine
    state.verb = verb
    state.label = label
    state.lean = 0
    state.companion = CGPoint(x: state.cursor.x + 7, y: state.cursor.y + 13)
    withAnimation(.spring(duration: Constants.HUD.anticipationSeconds, bounce: 0)) {
      state.target = nil
    }
  }
}
