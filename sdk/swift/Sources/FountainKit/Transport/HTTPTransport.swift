import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The seam between FountainKit and the network. Everything above this
/// protocol is deterministic and testable with a fake.
public protocol HTTPTransport: Sendable {
  /// Perform a request and buffer the whole response.
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Perform a request and stream the response body as it arrives
  /// (used for SSE). The response returns as soon as headers are in.
  func bytes(for request: URLRequest) async throws -> (
    HTTPURLResponse, AsyncThrowingStream<Data, Error>
  )
}

/// Production transport backed by URLSession.
public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw FountainError.transport(URLError(.badServerResponse))
    }
    return (data, http)
  }

  public func bytes(for request: URLRequest) async throws -> (
    HTTPURLResponse, AsyncThrowingStream<Data, Error>
  ) {
    // Not `session.bytes(for:)`: `URLSession.AsyncBytes` does not exist in
    // FoundationNetworking, so on Linux the only way to read a body as it
    // arrives is the data-task delegate.
    try await StreamingConnection.open(request: request, configuration: session.configuration)
  }
}

/// One streaming response, delivered chunk by chunk. The headers resolve
/// first — a caller needs the status before it decides whether the body is
/// a stream or an error — and the body follows on the returned stream.
private final class StreamingConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var opened: CheckedContinuation<HTTPURLResponse, any Error>?
  private var chunks: AsyncThrowingStream<Data, Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var finished = false

  static func open(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (
    HTTPURLResponse, AsyncThrowingStream<Data, Error>
  ) {
    let connection = StreamingConnection()
    // Built before the task starts, so bytes that arrive before the caller
    // iterates are buffered by the stream rather than dropped.
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      connection.chunks = continuation
      continuation.onTermination = { _ in connection.cancel() }
    }
    let session = URLSession(configuration: configuration, delegate: connection, delegateQueue: nil)
    connection.session = session
    let task = session.dataTask(with: request)
    connection.task = task

    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
      connection.lock.lock()
      connection.opened = continuation
      connection.lock.unlock()
      task.resume()
    }
    return (response, stream)
  }

  private func cancel() {
    lock.lock()
    let task = self.task
    let session = self.session
    self.task = nil
    lock.unlock()
    task?.cancel()
    session?.finishTasksAndInvalidate()
  }

  /// Resolve the headers exactly once, whether they arrived or the request
  /// died on the way out.
  private func settleOpen(_ result: Result<HTTPURLResponse, any Error>) {
    lock.lock()
    let continuation = opened
    opened = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      settleOpen(.failure(FountainError.transport(URLError(.badServerResponse))))
      completionHandler(.cancel)
      return
    }
    lock.lock()
    self.response = http
    lock.unlock()
    settleOpen(.success(http))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let continuation = finished ? nil : chunks
    lock.unlock()
    continuation?.yield(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let continuation = chunks
    let hadResponse = response != nil
    lock.unlock()

    defer { session.finishTasksAndInvalidate() }
    // A failure before any headers has nobody on the stream to tell yet.
    if let error, !hadResponse {
      settleOpen(.failure(FountainError.transport(error)))
      continuation?.finish(throwing: error)
      return
    }
    if !hadResponse {
      settleOpen(.failure(FountainError.transport(URLError(.badServerResponse))))
    }
    continuation?.finish(throwing: error)
  }
}
