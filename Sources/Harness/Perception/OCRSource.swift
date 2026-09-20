import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Tier 3 — screen capture plus on-device OCR.
///
/// The universal fallback. Works on any pixels: canvas, games, terminals,
/// Electron apps with no tree, video. Produces `label + bbox`, never `role` —
/// **no Apple framework returns a role from pixels.** All 34 Vision request
/// types were benchmarked during design; none knows what a button is, and
/// `DetectDocumentSegmentationRequest` returns zero regions on a screenshot,
/// because a screenshot is not paper.
///
/// **This is not a selection tier**, and `Constants.OCR.tier3FeedsMarksOnly`
/// says so. Vision returns *line* observations, so adjacent controls merge:
/// `"Donate Create account Log in"` is one box spanning three links. Splitting
/// by gap was implemented and measured to be impossible — inter-link and
/// intra-link spacing are identical at every resolution (2/2 px at DPR 1,
/// 6/5 px at DPR 3). Control boundaries have to come from the tier-3b detector,
/// which does not exist yet. Until it does, this output feeds tier 4's numbered
/// marks and is never selected from directly.
///
/// Everything here carries `provenance: .ocrLine`, and `CapturedExecutor`
/// refuses to execute that — ADR 0007. The refusal is the safety property, not
/// an unfinished edge.
public struct OCRSource: Sendable {
  public let pid: pid_t
  public let appName: String

  public init(pid: pid_t, appName: String) {
    self.pid = pid
    self.appName = appName
  }

  public init(appName: String) throws {
    self.pid = try WindowGuard.pid(forApp: appName)
    self.appName = appName
  }

  public struct Reading: Sendable {
    public let elements: [Element]
    /// What the capture itself cost, separately from recognition.
    public let captureMilliseconds: Int
    public let recognizeMilliseconds: Int
    public let imageWidth: Int
    public let imageHeight: Int
  }

  /// Captures the focused window and reads every line of text on it.
  public func read() async throws -> Reading {
    guard CGPreflightScreenCaptureAccess() else {
      throw ExecutionError.screenRecordingNotGranted
    }
    try WindowGuard.requireVisibleWindow(pid: pid, app: appName)

    let captureStarted = ContinuousClock.now
    let (image, origin) = try await capture()
    let captureMilliseconds = Int((ContinuousClock.now - captureStarted).inSeconds * 1000)

    let recognizeStarted = ContinuousClock.now
    var request = RecognizeTextRequest()
    // `.accurate`, never `.fast`. Measured on identical real pages, `.fast`
    // produced `Cr8ate`, `R&ad`, `Mlcrosoft`, `Hirln`; `.accurate` produced
    // none of them. 368 ms against 92 ms, and the budget absorbs it.
    request.recognitionLevel = Constants.OCR.useAccurateRecognition ? .accurate : .fast
    // "Corrects" filenames and truncated UI labels into prose. Off.
    request.usesLanguageCorrection = Constants.OCR.usesLanguageCorrection
    // MUST be 0. The Swift struct defaults this to 0.03125 — 1/32 of image
    // height — which returns ZERO observations on a Retina screenshot in
    // `.fast` mode. Measured sweep at 2880x1800, UI text about 0.0144:
    //   0.0 -> 86 obs · 0.010 -> 81 · 0.0144 -> 1 · 0.03125 (default) -> 0
    // Apple's ObjC header claims the default is 0.0. The Swift struct
    // measurably disagrees. Silent total failure, not an error.
    request.minimumTextHeightFraction = Float(Constants.OCR.minimumTextHeightFraction)

    let observations = try await request.perform(on: image)
    let recognizeMilliseconds = Int((ContinuousClock.now - recognizeStarted).inSeconds * 1000)

    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let scale = Constants.OCR.downscale ? 1.0 : CGFloat(Constants.OCR.retinaScale)

    let elements = observations.compactMap { observation -> Element? in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }

      // Vision reports a normalised rect with the origin at bottom-left.
      // Screen space is top-left and y-down, so the flip happens once, here,
      // at the boundary — code that carries two conventions eventually gets
      // one of them wrong.
      let box = observation.boundingBox.cgRect
      let bounds = CGRect(
        x: origin.x + (box.minX * width) / scale,
        y: origin.y + ((1 - box.maxY) * height) / scale,
        width: (box.width * width) / scale,
        height: (box.height * height) / scale
      )

      return Element(
        ref: .captured(bbox: bounds, label: text, provenance: .ocrLine),
        role: "",  // pixels carry no role, and inventing one would be a lie
        label: text,
        enabled: true,
        inViewport: true,
        bounds: bounds
      )
    }

    return Reading(
      elements: elements,
      captureMilliseconds: captureMilliseconds,
      recognizeMilliseconds: recognizeMilliseconds,
      imageWidth: image.width,
      imageHeight: image.height
    )
  }

  /// Captures the target window, retrying a transient failure.
  ///
  /// `-3811 SCStreamError` occurs even on windows that captured successfully a
  /// moment earlier, so a single attempt is not a valid observation.
  private func capture() async throws -> (CGImage, CGPoint) {
    var lastError: (any Error)?
    for attempt in 0..<Constants.OCR.captureRetries {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: true
        )
        guard
          let window = content.windows
            .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen })
            .max(by: { $0.frame.area < $1.frame.area })
        else { throw ExecutionError.windowNotVisible }

        let configuration = SCStreamConfiguration()
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
