import AppKit
import Harness
import SwiftUI

/// The native approval sheet. **The only safety boundary a human sees.**
///
/// Design constraints, each from a decision rather than a preference:
///
/// - **The exact payload, never a summary.** A summary is where an approval
///   boundary quietly stops meaning anything: the user approves "send a message"
///   and the message is not the one they read. The payload is shown verbatim,
///   selectable, and scrollable when long.
/// - **No timeout, ever.** `Constants.HUD.confirmationTimeout` is `nil` by
///   design. A timeout defaulting to yes is a hole; one defaulting to no kills a
///   task while the user is still reading.
/// - **Cancel is the default.** The destructive action is never the
///   return-key button. Apple's own guidance is to reserve confirmation for
///   genuinely irreversible actions and to keep the safe path the easy one —
///   overusing confirmation trains people to click through it, which is exactly
///   the failure this sheet exists to prevent.
/// - **Shown for irreversible actions only, never per turn.**
@MainActor
final class ApprovalSheet {

  /// Blocks until a human clicks. Runs a nested modal session so the overlay
  /// keeps drawing underneath and the ring stays on the target — the user can
  /// see exactly what the dialog is talking about.
  static func present(_ request: ConfirmationRequest) async -> Bool {
    await withCheckedContinuation { continuation in
      let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: Constants.HUD.confirmSize),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      panel.titlebarAppearsTransparent = true
      panel.titleVisibility = .hidden
      panel.isMovableByWindowBackground = true
      panel.level = .modalPanel
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = true
      // Follows the agent across Spaces and over full-screen apps, so the
      // approval never appears on a desktop the user is not looking at.
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

      let finish: (Bool) -> Void = { approved in
        panel.orderOut(nil)
        NSApp.stopModal()
        continuation.resume(returning: approved)
      }

      panel.contentView = NSHostingView(
        rootView: ApprovalView(request: request, decide: finish)
      )
      panel.center()
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      NSApp.runModal(for: panel)
    }
  }
}

// MARK: - View

private struct ApprovalView: View {
  let request: ConfirmationRequest
  let decide: (Bool) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  /// Amber, not red. Red reads as "error"; this is not an error, it is a
  /// decision the user is being handed. The colour matches the overlay's
  /// irreversible state so the ring on screen and the sheet agree.
  private var accent: Color {
    request.becauseIrreversible ? Color(red: 0.98, green: 0.65, blue: 0.16) : .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      if let payload = request.payload, !payload.isEmpty {
        payloadBlock(payload)
      }
      reason
      Spacer(minLength: 0)
      buttons
    }
    .padding(22)
    .frame(
      minWidth: Constants.HUD.confirmSize.width,
      minHeight: Constants.HUD.confirmSize.height,
      alignment: .topLeading
    )
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      // A bright top edge: light catching the material, the same cue the
      // system uses to make a translucent surface read as a real one.
      LinearGradient(
        colors: [.white.opacity(0.35), .clear],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 1)
    }
    .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
    .opacity(appeared ? 1 : 0)
    .onAppear {
      // Critically damped, response ~0.35. No overshoot: nothing about
      // this moment should feel playful, and the gesture that opened it
      // carried no momentum to inherit.
      withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.35, bounce: 0)) {
        appeared = true
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(
        systemName: request.becauseIrreversible
          ? "exclamationmark.triangle.fill" : "hand.raised.fill"
      )
      .foregroundStyle(accent)
      .font(.system(size: 15, weight: .semibold))
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        // Tight leading and slightly negative tracking, because this is
        // display-weight text and letters read too far apart as they grow.
        Text(request.headline)
          .font(.system(size: 17, weight: .semibold))
          .tracking(-0.2)
          .lineSpacing(0)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          request.becauseIrreversible
            ? "This cannot be undone."
            : "Flagged as risky (\(String(format: "%.2f", request.riskMax)))."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      }
    }
  }

  /// Verbatim. Selectable so the user can check it character by character,
  /// and scrollable so a long body is never silently clipped into looking
  /// shorter and more innocuous than it is.
  private func payloadBlock(_ payload: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Exactly this")
        .font(.system(size: 11, weight: .medium))
        .tracking(0.3)
        .foregroundStyle(.secondary)

      ScrollView {
        Text(payload)
          .font(.system(size: 12.5, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(maxHeight: 108)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(Color.primary.opacity(0.09))
      )
    }
  }

  private var reason: some View {
    Text(request.rationale)
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Spacer()
      // Cancel carries the return key. The destructive path must never be
      // the one a reflexive keypress takes.
      Button("Cancel") { decide(false) }
        .keyboardShortcut(.defaultAction)

      Button(request.actionKind.rawValue.capitalized) { decide(true) }
        .keyboardShortcut(.none)
        .tint(accent)
    }
    .controlSize(.large)
  }
}
