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
        let options = CLI.parse(CommandLine.arguments)
        Task { @MainActor in
            await CursorDemo.run(options)
            if !options.loop { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Options

/// A deliberately small surface for looking at the overlay.
///
/// It exists because the motion, the timing and the narration are product
/// decisions, and a product decision you can only evaluate by editing a constant
/// and rebuilding is a product decision nobody evaluates more than once.
struct CLI {
    var loop = false
    var speed: Double = 1.0
    var single: CGRect?
    var verb = "click"
    var label = "Send"
    var intent: CursorIntent = .routine

    static func parse(_ argv: [String]) -> CLI {
        var o = CLI()
        var i = 1
        func next() -> String? { i + 1 < argv.count ? argv[i + 1] : nil }

        while i < argv.count {
            switch argv[i] {
            case "--loop":
                o.loop = true
            case "--speed":
                if let v = next().flatMap(Double.init) { o.speed = max(0.1, min(v, 5)) }
                i += 1
            case "--at":
                // Fractions of the main display, so it reads the same on any screen.
                let parts = (next() ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    let s = CGDisplayBounds(CGMainDisplayID())
                    o.single = CGRect(x: s.minX + s.width * parts[0],
                                      y: s.minY + s.height * parts[1],
                                      width: 132, height: 34)
                }
                i += 1
            case "--verb":
                o.verb = next() ?? o.verb; i += 1
            case "--label":
                o.label = next() ?? o.label; i += 1
            case "--danger":
                o.intent = .irreversible
            case "--help", "-h":
                print(help); exit(0)
            default:
                break
            }
            i += 1
        }
        return o
    }

    static let help = """
    computer-agent — cursor overlay

      swift run ComputerAgent                    scripted mail task, once
      swift run ComputerAgent --loop             repeat until Ctrl-C
      swift run ComputerAgent --speed 0.4        slow the easing down to look at it
      swift run ComputerAgent --at 0.8,0.2 \\
          --verb send --label "Send" --danger    one move + click, amber

    --at takes fractions of the main display (0,0 top-left) so it reads the
    same on any screen. --danger is the colour an irreversible action gets.

    Tuning lives in Sources/Harness/Config/Constants.swift § HUD (timing) and
    Sources/ComputerAgent/HUD/CursorView.swift (everything visual).
    """
}

// MARK: - Demo

/// A scripted walk-through of the mail task, with no harness behind it.
///
/// The rects below are invented. Every one of them arrives from
/// `Element.bounds` once perception is wired in — the overlay itself does not
/// change, because it never computed a target in the first place.
@MainActor
enum CursorDemo {

    static func run(_ options: CLI) async {
        let overlay = CursorOverlay.shared
        overlay.speedScale = options.speed
        overlay.show()

        if let rect = options.single {
            await step(overlay, rect, options.verb, options.label, options.intent)
            try? await Task.sleep(for: .seconds(0.6))
            overlay.hide()
            try? await Task.sleep(for: .seconds(0.4))
            return
        }

        print("▸ computer-agent — cursor overlay")
        print("  narrating a mail task with no harness behind it")
        print("  --help for the knobs\(options.loop ? " · Ctrl-C to stop" : "")\n")

        repeat {
            await script(overlay)
            if options.loop { try? await Task.sleep(for: .seconds(1.0)) }
        } while options.loop

        print("▸ done")
    }

    private static func script(_ overlay: CursorOverlay) async {
        // Quartz screen space: origin at the primary display's top-left, y down.
        // This is what AX, ScreenCaptureKit and CGEvent all speak, so the demo
        // speaks it too rather than inventing a friendlier convention.
        let screen = CGDisplayBounds(CGMainDisplayID())
        func at(_ fx: Double, _ fy: Double, _ w: Double = 132, _ h: Double = 34) -> CGRect {
            CGRect(x: screen.minX + screen.width * fx,
                   y: screen.minY + screen.height * fy,
                   width: w, height: h)
        }

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
