import AppKit
import Harness
import SwiftUI

@main
struct ComputerAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // No main window. The agent's interface is the overlay it draws over other
    // people's applications, plus the HUD — not a window of its own.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        Task { @MainActor in
            await CursorDemo.run()
            NSApp.terminate(nil)
        }
    }
}

/// A scripted walk-through of the mail task, with no harness behind it.
///
/// It exists to make the overlay reviewable on its own: the motion, narration
/// and confirmation colour are product decisions that have to be *watched* to be
/// judged, and waiting for the loop to exist before looking at them would mean
/// judging them at the point they are most expensive to change.
///
/// The rects below are invented. Every one of them arrives from
/// `Element.bounds` once perception is wired in — the overlay itself does not
/// change, because it never computed a target in the first place.
@MainActor
enum CursorDemo {

    static func run() async {
        let overlay = CursorOverlay.shared
        overlay.show()

        // Quartz screen space: origin at the primary display's top-left, y down.
        // This is what AX, ScreenCaptureKit and CGEvent all speak, so the demo
        // speaks it too rather than inventing a friendlier convention.
        let screen = CGDisplayBounds(CGMainDisplayID())
        func at(_ fx: Double, _ fy: Double, _ w: Double = 132, _ h: Double = 34) -> CGRect {
            CGRect(x: screen.minX + screen.width * fx,
                   y: screen.minY + screen.height * fy,
                   width: w, height: h)
        }

        print("▸ computer-agent — cursor overlay demo")
        print("  watch the screen; this narrates a mail task with no harness behind it\n")

        overlay.announce(verb: "open", label: "Zen Browser")
        try? await Task.sleep(for: .seconds(0.9))

        overlay.announce(verb: "navigate", label: "outlook.office.com/mail")
        try? await Task.sleep(for: .seconds(1.1))

        await step(overlay, at(0.09, 0.19, 104, 32), "click", "New mail")
        await step(overlay, at(0.46, 0.31, 260, 30), "click", "To")
        await step(overlay, at(0.46, 0.31, 260, 30), "type", "ahammadnafiz86@gmail.com")
        await step(overlay, at(0.46, 0.31, 260, 30), "press", "Enter — commits the recipient")
        await step(overlay, at(0.46, 0.38, 260, 30), "type", "ICCIT paper")
        await step(overlay, at(0.46, 0.50, 300, 90), "type", "Hi — sending the ICCIT draft…")

        // The one action that gets confirmed. Amber, and the ring sits on the
        // target while the sheet is up, so the user can see exactly what the
        // dialog is talking about.
        await step(overlay, at(0.80, 0.19, 88, 32), "send", "Send", .irreversible)

        try? await Task.sleep(for: .seconds(0.5))
        overlay.hide()
        try? await Task.sleep(for: .seconds(0.4))
        print("▸ done")
    }

    private static func step(
        _ overlay: CursorOverlay,
        _ rect: CGRect,
        _ verb: String,
        _ label: String,
        _ intent: CursorIntent = .routine
    ) async {
        await overlay.move(to: rect, verb: verb, label: label, intent: intent)
        await overlay.press()
        try? await Task.sleep(for: .seconds(0.25))
    }
}
