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
///
/// The `session` a caller supplies is read for its configuration, not used
/// directly: this transport owns the two sessions it cancels tasks on, and
/// builds both without a `URLCache`. See `transportConfiguration(from:)`.
public struct URLSessionTransport: HTTPTransport {
  private let requests: RequestSession
  private let streamer: StreamingSession

  public init(session: URLSession = .shared) {
    let transport = URLSessionTransport.transportConfiguration(from: session)
    self.requests = RequestSession(configuration: transport)
    self.streamer = StreamingSession(configuration: transport)
  }

  /// The configuration both sessions are built from: the caller's, minus its
  /// `URLCache`.
  ///
  /// This transport cancels the tasks it starts, and on Linux that is only safe
  /// on a cacheless session. FoundationNetworking looks a cached response up on
  /// a background queue before it creates the task's `URLProtocol`, so a cancel
  /// that lands in that window reports its failure once the task has already
  /// left the task registry, and `URLSession.behaviour(for:)` traps the whole
  /// process rather than returning nil. Over 40,000 cancel-after-resume rounds
  /// in `swift:6.1`, every batch with a cache trapped and no batch without one
  /// did (#1410). `URLSession.shared`, the default here, carries
  /// `URLCache.shared`.
  ///
  /// Nothing is lost by dropping it. Fountain answers every request under an
  /// `Authorization` header and sends no cache headers, and an event stream
  /// must never be replayed out of a cache.
  private static func transportConfiguration(from session: URLSession)
    -> URLSessionConfiguration
  {
    let configuration = session.configuration
    let copy = (configuration.copy() as? URLSessionConfiguration) ?? configuration
    copy.urlCache = nil
    copy.requestCachePolicy = .reloadIgnoringLocalCacheData
    return copy
  }

  /// Not `session.data(for:)`. See `RequestCancellation` for why.
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let cancellation = RequestCancellation()
    let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        let task = requests.session.dataTask(with: request) { data, response, error in
          cancellation.clear()
          if let error {
            continuation.resume(throwing: error)
          } else if let response {
            continuation.resume(returning: (data ?? Data(), response))
          } else {
            continuation.resume(throwing: URLError(.badServerResponse))
          }
        }
        task.resume()
        cancellation.activate(task)
      }
    } onCancel: {
      cancellation.cancel()
    }
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
    try await streamer.open(request: request)
  }
}

/// The session plain requests run on, held so that it is invalidated once, when
/// the transport that owns it is released.
private final class RequestSession: @unchecked Sendable {
  let session: URLSession

  init(configuration: URLSessionConfiguration) {
    session = URLSession(configuration: configuration)
  }

  deinit { session.finishTasksAndInvalidate() }
}

/// One `URLSession` for every streaming request a transport opens, and one
/// delegate that fans its callbacks back out by `URLSessionTask.taskIdentifier`.
///
/// A delegate that holds per-connection state needs a session of its own, which
/// is why this used to build one per request. FoundationNetworking cannot take
/// that: releasing the delegate means invalidating the session, and doing it
/// from inside `didCompleteWithError` runs while that task's completion is
/// still in flight (#1410). So: one session, invalidated once when the
/// transport that owns this is released, and never from inside a callback.
private final class StreamingSession: @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  /// A separate object rather than `self`, because the session holds its
  /// delegate until it is invalidated. Were `self` the delegate, `deinit` would
  /// wait on the invalidation it is meant to perform.
  private let delegate = StreamingDelegate()
  private let lock = NSLock()
  private var session: URLSession?

  init(configuration: URLSessionConfiguration) {
    self.configuration = configuration
  }

  deinit { session?.finishTasksAndInvalidate() }

  /// The headers resolve first — a caller needs the status before it decides
  /// whether the body is a stream or an error — and the body follows on the
  /// returned stream.
  func open(request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
  {
    let task = openSession().dataTask(with: request)
    let connection = StreamingConnection(task: task)
    // Built before the task starts, so bytes that arrive before the caller
    // iterates are buffered by the stream rather than dropped.
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      connection.chunks = continuation
      continuation.onTermination = { _ in connection.cancel() }
    }
    // Registered before `resume()`, so no callback can arrive before the
    // delegate can route it.
    delegate.register(connection, for: task)

    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
      connection.settleOnOpen(continuation)
      task.resume()
    }
    return (response, stream)
  }

  /// Built on the first stream, so a transport that never streams never makes
  /// one.
  private func openSession() -> URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let session { return session }
    let created = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    session = created
    return created
  }
}

/// Task identifiers are unique for the life of a session, so a finished task
/// never hands its slot to a later one.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [Int: StreamingConnection] = [:]

  func register(_ connection: StreamingConnection, for task: URLSessionDataTask) {
    lock.lock()
    defer { lock.unlock() }
    connections[task.taskIdentifier] = connection
  }

  private func connection(for task: URLSessionTask) -> StreamingConnection? {
    lock.lock()
    defer { lock.unlock() }
    return connections[task.taskIdentifier]
  }

  private func take(_ task: URLSessionTask) -> StreamingConnection? {
    lock.lock()
    defer { lock.unlock() }
    return connections.removeValue(forKey: task.taskIdentifier)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let connection = connection(for: dataTask) else {
      completionHandler(.cancel)
      return
    }
    completionHandler(connection.receive(response) ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    connection(for: dataTask)?.receive(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    take(task)?.complete(error)
  }
}

/// The per-connection half: the headers continuation, the chunk continuation
/// and the status. It owns no session, and invalidates none.
private final class StreamingConnection: @unchecked Sendable {
  private let task: URLSessionDataTask
  private let lock = NSLock()
  private var opened: CheckedContinuation<HTTPURLResponse, any Error>?
  private var response: HTTPURLResponse?
  private var finished = false
  /// Set once, inside the stream's build closure, before the task resumes.
  var chunks: AsyncThrowingStream<Data, Error>.Continuation?

  init(task: URLSessionDataTask) {
    self.task = task
  }

  func settleOnOpen(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
    lock.lock()
    opened = continuation
    lock.unlock()
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

  /// Returns whether the body should be allowed through.
  func receive(_ response: URLResponse) -> Bool {
    guard let http = response as? HTTPURLResponse else {
      settleOpen(.failure(FountainError.transport(URLError(.badServerResponse))))
      return false
    }
    lock.lock()
    self.response = http
    lock.unlock()
    settleOpen(.success(http))
    return true
  }

  func receive(_ data: Data) {
    lock.lock()
    let continuation = finished ? nil : chunks
    lock.unlock()
    continuation?.yield(data)
  }

  func complete(_ error: (any Error)?) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let continuation = chunks
    let hadResponse = response != nil
    lock.unlock()

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

  /// A caller that walks away from a live body has to cancel the task, or the
  /// connection stays open. A caller that read to the end has nothing to
  /// cancel. This is safe to call whatever the task is doing only because the
  /// session carries no `URLCache` — see
  /// `URLSessionTransport.transportConfiguration(from:)`.
  func cancel() {
    lock.lock()
    let alreadyFinished = finished
    finished = true
    lock.unlock()
    if !alreadyFinished { task.cancel() }
  }
}

/// Holds the `URLSessionTask` a request is running on, and lets go of it the
/// moment the response lands.
///
/// This is why `URLSession.data(for:)` is not used. Its own version of this
/// never lets go: it keeps the task for the whole call, so a Swift task
/// cancelled just after the response arrived still cancels the
/// `URLSessionTask`. Letting go on completion means the common case cancels
/// nothing at all; `transportConfiguration(from:)` is what makes the cancels
/// that do happen safe.
private final class RequestCancellation: @unchecked Sendable {
  private enum State {
    case pending
    case completed
    case cancelled
  }

  private let lock = NSLock()
  private var state = State.pending
  private var task: URLSessionTask?

  /// Called from the completion handler. A request that answered is not
  /// cancelled, whatever happens to the Swift task afterwards.
  func clear() {
    lock.lock()
    state = .completed
    task = nil
    lock.unlock()
  }

  /// Called after `resume()`, so it has to cope with a request that answered,
  /// or was cancelled, before it got here.
  func activate(_ task: URLSessionTask) {
    lock.lock()
    let state = self.state
    if state == .pending { self.task = task }
    lock.unlock()
    if state == .cancelled { task.cancel() }
  }

  func cancel() {
    lock.lock()
    let task = self.task
    if state == .pending { state = .cancelled }
    self.task = nil
    lock.unlock()
    task?.cancel()
  }
}
