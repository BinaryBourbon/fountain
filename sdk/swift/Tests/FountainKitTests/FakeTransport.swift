import Foundation

@testable import FountainKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Scripted transport: each call pops the next canned response and records
/// the request it answered. Response shapes in these tests are taken from
/// real API responses (managoat.com, 2026-08-31), not invented — the fake
/// once wrapping what the real API leaves bare is a known trap.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
  struct Canned {
    var status: Int
    var body: Data
    var headers: [String: String]

    init(status: Int = 200, json: String, headers: [String: String] = [:]) {
      self.status = status
      self.body = Data(json.utf8)
      self.headers = headers
    }
  }

  private let lock = NSLock()
  private var responses: [Canned]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [Canned]) {
    self.responses = responses
  }

  convenience init(json: String, status: Int = 200, headers: [String: String] = [:]) {
    self.init([Canned(status: status, json: json, headers: headers)])
  }

  private func next(for request: URLRequest) -> Canned {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    return responses.isEmpty ? Canned(status: 500, json: "{}") : responses.removeFirst()
  }

  var lastRequest: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return requests.last
  }

  private func httpResponse(_ canned: Canned, url: URL?) -> HTTPURLResponse {
    HTTPURLResponse(
      url: url ?? URL(string: "https://fountain.test")!,
      statusCode: canned.status,
      httpVersion: "HTTP/1.1",
      headerFields: canned.headers
    )!
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let canned = next(for: request)
    return (canned.body, httpResponse(canned, url: request.url))
  }

  func bytes(for request: URLRequest) async throws -> (
    HTTPURLResponse, AsyncThrowingStream<Data, Error>
  ) {
    let canned = next(for: request)
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(canned.body)
      continuation.finish()
    }
    return (httpResponse(canned, url: request.url), stream)
  }
}

extension FountainClient {
  static func fake(_ transport: FakeTransport) -> FountainClient {
    FountainClient(
      config: FountainConfig(
        baseURL: URL(string: "https://fountain.test")!,
        apiKey: "ftn_live_test"
      ),
      transport: transport
    )
  }
}
