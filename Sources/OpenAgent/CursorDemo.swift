import AppKit
import Harness
import SwiftUI

// MARK: - Demo

/// A scripted walk-through of the mail task, with no harness behind it.
///
/// The rects below are invented. Every one of them arrives from
/// `Element.bounds` once perception is wired in — the overlay itself does not
/// change, because it never computed a target in the first place.
@MainActor
enum CursorDemo {

  static func run(_ options: CLI.Options) async {
    let overlay = CursorOverlay.shared
    overlay.speedScale = options.speed
    overlay.show()

    if let rect = options.single {
      // `--loop` applies here too. It previously did not, so
      // `--at … --danger --loop` rendered one frame and exited, which makes the
      // one state you most want to sit and look at the one you cannot.
      repeat {
        await step(overlay, rect, options.overlayVerb, options.label, options.intent)
        try? await Task.sleep(for: .seconds(0.6))
        if !options.loop { overlay.hide() }
      } while options.loop
      try? await Task.sleep(for: .seconds(0.4))
      return
    }

    // stderr, not stdout. `overlay` is an ordinary verb and stdout carries one
    // JSON object per invocation and nothing else — a host that has to pick
    // prose out of stdout will eventually pick it out wrong.
    Log.info("cursor overlay — narrating a mail task with no harness behind it")
    Log.info("--help for the knobs\(options.loop ? " · Ctrl-C to stop" : "")")

    repeat {
      await script(overlay)
      if options.loop { try? await Task.sleep(for: .seconds(1.0)) }
    } while options.loop

    Log.info("done")
  }

  private static func script(_ overlay: CursorOverlay) async {
    // Quartz screen space: origin at the primary display's top-left, y down.
    // This is what AX, ScreenCaptureKit and CGEvent all speak, so the demo
    // speaks it too rather than inventing a friendlier convention.
    let screen = CGDisplayBounds(CGMainDisplayID())
    func at(_ fx: Double, _ fy: Double, _ w: Double = 132, _ h: Double = 34) -> CGRect {
      CGRect(
        x: screen.minX + screen.width * fx,
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
