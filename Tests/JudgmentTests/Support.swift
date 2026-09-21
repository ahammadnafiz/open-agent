import Foundation
import Testing

@testable import Harness

/// A scripted transport. Returns the next queued response per call, so a test
/// can assert exactly how many attempts were made.
actor FakeTransport: JevTransport {
  struct Reply: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
    /// When set, `send` throws this instead of returning.
    var error: JevError?
  }

  private var replies: [Reply]
  private(set) var sentRequests: [URLRequest] = []
  /// Every base URL `warm` was asked to open, so a test can prove the call
  /// reaches the transport rather than the protocol's default.
  private(set) var warmed: [URL] = []

  init(_ replies: [Reply]) { self.replies = replies }

  var callCount: Int { sentRequests.count }

  func warm(_ baseURL: URL) async { warmed.append(baseURL) }

  func send(_ request: URLRequest, timeout: Duration) async throws -> (Data, HTTPURLResponse) {
    sentRequests.append(request)
    guard !replies.isEmpty else {
      throw JevError.malformedResponse(field: "FakeTransport ran out of scripted replies")
    }
    let reply = replies.removeFirst()
    if let error = reply.error { throw error }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status,
      httpVersion: "HTTP/1.1", headerFields: reply.headers
    )!
    return (reply.body, response)
  }
}

enum Fixture {
  /// A complete, well-formed batch response. Probabilities are string-keyed,
  /// exactly as the HTTP API returns them.
  static func fullBatch(
    model: String = Constants.Models.jev,
    targetProbabilities: [String: Double] = ["e0": 0.91, "e1": 0.06, "e2": 0.03],
    confidence: Double = 0.87,
    sufficient: Double = 0.93,
    includeWrongContext: Bool = false
  ) -> Data {
    var answers: [String: Any] = [
      "progressed": ["type": "noul", "noul": 0.97],
      "unchanged": ["type": "noul", "noul": 0.03],
      "blocked": ["type": "noul", "noul": 0.04],
      "task_done": ["type": "noul", "noul": 0.05],
      "looping": ["type": "noul", "noul": 0.05],
      "sufficient": ["type": "noul", "noul": sufficient],
      "risk_destructive": ["type": "noul", "noul": 0.02],
      "risk_outbound": ["type": "noul", "noul": 0.11],
      "risk_credential": ["type": "noul", "noul": 0.01],
      "target": [
        "type": "choice",
        "choice": targetProbabilities.max(by: { $0.value < $1.value })!.key,
        "probabilities": targetProbabilities,
        "confidence": confidence,
      ],
    ]
    if includeWrongContext {
      answers["wrong_context"] = ["type": "noul", "noul": 0.08]
    }
    let root: [String: Any] = [
      "model": model,
      "answers": answers,
      "usage": ["input_tokens": 1_240, "output_tokens": 180],
    ]
    return try! JSONSerialization.data(withJSONObject: root)
  }

  static func context(
    candidates: [String: String] = ["e0": "Post", "e1": "Home", "e2": "Explore"],
    taskContext: String = ""
  ) -> StepContext {
    StepContext(
      task: "write a short post and publish it",
      planStep: PlanStepDTO(kind: "click", target: "the compose button", payload: nil),
      lastAction: ActionDTO(
        kind: "navigate", target: "address bar", payload: "https://example.com"),
      screenBefore: "<a> Home\n<button> Post",
      screenNow: "<dialog> Create Post\n<textbox> What is happening?!",
      recentHistory: ["openApp Zen", "navigate example.com"],
      candidates: candidates,
      taskContext: taskContext
    )
  }

  /// A client wired to a fake transport, with sleep and jitter made
  /// deterministic so retry timing is assertable.
  static func client(
    _ transport: FakeTransport,
    policy: RetryPolicy = RetryPolicy(),
    recordSleeps: @escaping @Sendable (Duration) -> Void = { _ in }
  ) -> JevClient {
    JevClient(
      apiKey: "test-key-not-a-real-credential",
      transport: transport,
      policy: policy,
      sleep: { d in recordSleeps(d) },
      random: { 0.5 }  // jitter midpoint → scale 1.0
    )
  }
}
