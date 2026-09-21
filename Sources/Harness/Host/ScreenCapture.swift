import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the target window and draws the candidate boxes on it as numbered
/// marks — Set-of-Marks, exactly as ADR 0004 decided it.
///
/// **Scope is the focused window, not the display.** A full-screen capture
/// includes the agent's own cursor overlay and every other application:
/// irrelevant context that costs both accuracy and tokens, and that puts more
/// of the user's screen into the host's context than the task needs.
///
/// **Privacy, stated plainly:** an escalation puts an image of the window into
/// the host agent's context, and from there wherever that host sends it. A task
/// operating on a window with sensitive content will transmit it.
public struct ScreenCapture: ScreenCapturing {
  public init() {}

  public func captureWithMarks(
    pid: pid_t, candidates: [Element], to url: URL
  ) async throws -> (path: String, frameHash: String) {

    guard CGPreflightScreenCaptureAccess() else {
      throw ExecutionError.screenRecordingNotGranted
    }

    let scale = Constants.OCR.downscale ? 1 : Constants.OCR.retinaScale
    let (image, origin) = try await WindowCapture.retrying(pid: pid)

    let marked = try MarkRenderer.draw(
      candidates: candidates, on: image, windowOrigin: origin, scale: CGFloat(scale)
    )

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let data = try MarkRenderer.png(marked)
    try data.write(to: url, options: .atomic)

    // The bbox is meaningless without the frame it was measured in. The log
    // carries this or the step is unreplayable — ADR 0007.
    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    return (url.path, String(hash.prefix(Constants.OCR.frameHashLength)))
  }
}

/// One window, captured, retrying the failures that are not answers.
///
/// **A single attempt is not a valid observation.** `-3811 SCStreamError`
/// occurs on windows that captured successfully a moment earlier, and
/// `SCShareableContent` intermittently omits a window that is plainly on
/// screen — the same lesson `AXSource` records about `AXWindows`.
///
/// The OCR tier learned this and hardened its own capture; the escalation
/// capture did not, and the difference is exactly the reported defect. A
/// `needs_eyes` came back with no screenshot at all on the first try and with
/// one on the second, leaving the host to resolve the target from candidate
/// text — which a host with no candidate list cannot do.
///
/// Shared rather than copied, because the copy without the retry is the bug.
enum WindowCapture {

  /// - Returns: the captured image and the window's origin on screen.
  static func retrying(pid: pid_t) async throws -> (CGImage, CGPoint) {
    var lastError: (any Error)?
    for attempt in 0..<Constants.OCR.captureRetries {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: true
        )
        // Largest on-screen window belonging to the target process. Same rule
        // as `WindowGuard`: never simply the first, which for Finder is the
        // desktop.
        guard
          let window = content.windows
            .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen })
            .max(by: { $0.frame.area < $1.frame.area })
        else { throw ExecutionError.windowNotVisible }

        let configuration = SCStreamConfiguration()
        // Native Retina scale, never downscaled. Measured: at 1x, recall of
        // known UI labels was 21/34 and missed the entire menu bar; at 2x, 34/34.
        let scale = Constants.OCR.downscale ? 1 : Constants.OCR.retinaScale
        configuration.width = Int(window.frame.width) * scale
        configuration.height = Int(window.frame.height) * scale
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: window),
          configuration: configuration
        )
        return (image, window.frame.origin)
      } catch {
        lastError = error
        if attempt < Constants.OCR.captureRetries - 1 {
          try? await Task.sleep(for: Constants.OCR.captureRetryDelay)
        }
      }
    }
    throw lastError ?? ExecutionError.windowNotVisible
  }
}

/// Draws numbered boxes onto a captured frame.
///
/// The number is what the host answers with. **No model in this system ever
/// emits a coordinate** — asking for a point measures worse, ScreenSpot-Pro puts
/// coordinate regression at 17.1 where marks took GPT-4V from 16.2 to 73.0.
public enum MarkRenderer {

  public static func draw(
    candidates: [Element],
    on image: CGImage,
    windowOrigin: CGPoint,
    scale: CGFloat
  ) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw ExecutionError.graphicsFailed(stage: "CGContext")
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    for (index, element) in candidates.enumerated() {
      // Element bounds are in Quartz screen space (origin top-left, y down).
      // CGContext is bottom-up, so y is flipped once, here, at the boundary.
      let local = CGRect(
        x: (element.bounds.minX - windowOrigin.x) * scale,
        y: CGFloat(height) - (element.bounds.maxY - windowOrigin.y) * scale,
        width: element.bounds.width * scale,
        height: element.bounds.height * scale
      )
      guard local.area > 0 else { continue }

      context.setStrokeColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 0.95)
      context.setLineWidth(2 * scale)
      context.stroke(local)

      // The badge sits at the top-left corner of the box, outside it where
      // there is room, so it never covers the control it is labelling.
      let badgeSide = 20 * scale
      let badge = CGRect(
        x: local.minX, y: local.maxY - badgeSide,
        width: badgeSide, height: badgeSide
      )
      context.setFillColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 0.95)
      context.fill(badge)

      drawNumber(index + 1, in: badge, context: context, scale: scale)
    }

    guard let output = context.makeImage() else {
      throw ExecutionError.graphicsFailed(stage: "CGContext.makeImage")
    }
    return output
  }

  /// Draws the mark number using CoreText.
  private static func drawNumber(_ number: Int, in rect: CGRect, context: CGContext, scale: CGFloat)
  {
    let text = "\(number)"
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 13 * scale, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes)
    )
    let bounds = CTLineGetBoundsWithOptions(line, [])
    context.textPosition = CGPoint(
      x: rect.midX - bounds.width / 2,
      y: rect.midY - bounds.height / 2 + bounds.height * 0.18
    )
    CTLineDraw(line, context)
  }

  public static func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
      )
    else {
      throw ExecutionError.graphicsFailed(stage: "CGImageDestinationCreateWithData")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ExecutionError.graphicsFailed(stage: "CGImageDestinationFinalize")
    }
    return data as Data
  }
}
