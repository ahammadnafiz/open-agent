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

    /// Multiplies pointer velocity. 1.0 is `Constants.HUD.pixelsPerSecond`.
    ///
    /// Exists so the motion can be judged at half and double speed without a
    /// rebuild — the easing curve is a product decision and product decisions
    /// need to be *watched*, repeatedly, before anyone can have an opinion.
    /// It is an instance property rather than a constant because it is a
    /// debugging affordance, not a tuned value; the shipped value lives in
    /// `Constants.HUD`.
    public var speedScale: Double = 1.0

    private init() {}

    // MARK: - Lifecycle

    public func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
        state.isVisible = true
    }

    public func hide() {
        state.isVisible = false
        state.verb = ""
        state.target = nil
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
            .canJoinAllSpaces,      // follow the user across Spaces
            .stationary,            // do not slide during Space transitions
            .fullScreenAuxiliary,   // survive over full-screen apps
            .ignoresCycle,          // never appear in Cmd-` rotation
        ]

        p.contentView = NSHostingView(rootView: CursorOverlayView(state: state))
        panel = p

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
    public func move(
        to bounds: CGRect,
        verb: String,
        label: String,
        intent: CursorIntent = .routine
    ) async {
        guard Constants.HUD.motionEnabled else { return }
        show()

        let local = Self.toLocal(bounds)
        let destination = CGPoint(x: local.midX, y: local.midY)
        let distance = hypot(destination.x - state.cursor.x, destination.y - state.cursor.y)

        // Duration scales with distance, the way a real pointer does. A fixed
        // duration makes short hops feel sluggish and long sweeps feel frantic.
        let travel = min(
            max(distance / Constants.HUD.pixelsPerSecond, Constants.HUD.minMoveSeconds),
            Constants.HUD.maxMoveSeconds
        ) / speedScale

        state.intent = intent
        state.verb = verb
        state.label = label

        // The ring lands first. Anticipation is the whole point of the overlay:
        // the user sees WHERE before they see WHAT.
        withAnimation(.easeOut(duration: Constants.HUD.anticipationSeconds)) {
            state.target = local
        }
        try? await Task.sleep(for: .seconds(Constants.HUD.anticipationSeconds))

        withAnimation(.spring(response: travel, dampingFraction: 0.86)) {
            state.cursor = destination
        }
        try? await Task.sleep(for: .seconds(travel))
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
        withAnimation(.easeOut(duration: 0.25)) { state.target = nil }
    }

    /// Narration with no movement — for steps that have no on-screen target,
    /// such as `navigate`, `openApp` and `wait`.
    public func announce(verb: String, label: String) {
        guard Constants.HUD.motionEnabled else { return }
        show()
        state.intent = .routine
        state.verb = verb
        state.label = label
        withAnimation(.easeOut(duration: 0.2)) { state.target = nil }
    }
}
