import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// `URLRequest.timeoutInterval` bounds the gap between packets, not the life of
/// the whole stream, so a day of silence stands in for "no timeout" on a feed
/// that heartbeats. `.greatestFiniteMagnitude` cannot be used: it is out of
/// range for the integer timeout FoundationNetworking derives from it on Linux,
/// and that conversion traps rather than clamping.
let fountainStreamTimeout: TimeInterval = 24 * 60 * 60

public final class FountainHTTPClient: @unchecked Sendable {
  public let configuration: FountainConfiguration
  public let timeout: TimeInterval
  /// The caller's `session` is read for its configuration, not used directly.
  /// See `transportConfiguration(from:)`.
  private let transport: URLSessionConfiguration
  private let lock = NSLock()
  private var openRequests: URLSession?
  private var openStreamer: SSEStreamer?

  public init(
    configuration: FountainConfiguration, timeout: TimeInterval = 30, session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.timeout = timeout
    self.transport = Self.transportConfiguration(from: session)
  }

  deinit { openRequests?.finishTasksAndInvalidate() }

  /// The configuration both of this client's sessions are built from: the one
  /// the caller supplied, minus its `URLCache`.
  ///
  /// The SDK cancels the tasks it starts, and on Linux that is only safe on a
  /// cacheless session. FoundationNetworking looks a cached response up on a
  /// background queue before it creates the task's `URLProtocol`, so a cancel
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
  private static func transportConfiguration(from session: URLSession) -> URLSessionConfiguration {
    let configuration = session.configuration
    let copy = (configuration.copy() as? URLSessionConfiguration) ?? configuration
    copy.urlCache = nil
    copy.requestCachePolicy = .reloadIgnoringLocalCacheData
    return copy
  }

  /// One session for plain requests, built on the first one. Streams get their
  /// own (`streamer`): a handful of tailing connections would otherwise fill
  /// `httpMaximumConnectionsPerHost` and queue every API call behind them.
  private var requests: URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let openRequests { return openRequests }
    let created = URLSession(configuration: transport)
    openRequests = created
    return created
  }

  public func url(path: String, query: [String: String?] = [:]) -> URL {
    let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let joined =
      configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      + "/" + trimmedPath
    let base =
      URL(string: path).flatMap { $0.scheme == nil ? nil : $0 }
      ?? URL(string: joined)
      ?? configuration.baseURL
    guard !query.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { return base }
    let items = query.compactMap { key, value -> URLQueryItem? in
      guard let value, !value.isEmpty else { return nil }
      return URLQueryItem(name: key, value: value)
    }.sorted { $0.name < $1.name }
    if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
    return components.url ?? base
  }

  public func makeRequest(
    _ method: String,
    _ path: String,
    query: [String: String?] = [:],
    body: JSONValue? = nil,
    accept: String = "application/json"
  ) throws -> URLRequest {
    guard !configuration.apiKey.isEmpty else {
      throw FountainError(
        .authentication,
        "No Fountain API key. Pass apiKey, set FOUNTAIN_API_KEY, or run `fountain auth login`.")
    }
    var request = URLRequest(url: url(path: path, query: query))
    request.httpMethod = method.uppercased()
    request.timeoutInterval = timeout
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("fountain-sdk-swift/\(fountainSDKVersion)", forHTTPHeaderField: "User-Agent")
    if let parent = configuration.parentConversationID {
      request.setValue(parent, forHTTPHeaderField: "X-Fountain-Parent-Conversation-Id")
    }
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  public func request(
    _ method: String,
    _ path: String,
    query: [String: String?] = [:],
    body: JSONValue? = nil
  ) async throws -> JSONValue {
    let request = try makeRequest(method, path, query: query, body: body)
    do {
      let (data, response) = try await perform(request)
      guard let http = response as? HTTPURLResponse else {
        throw FountainError(
          .connection,
          "\(method.uppercased()) \(request.url!.absoluteString) returned no HTTP response")
      }
      let decoded =
        data.isEmpty
        ? .null
        : (try? JSONDecoder().decode(JSONValue.self, from: data))
          ?? .string(String(decoding: data, as: UTF8.self))
      guard (200..<300).contains(http.statusCode) else {
        throw fountainError(
          status: http.statusCode, body: decoded, method: method.uppercased(), url: request.url!,
          headers: http.allHeaderFields)
      }
      return decoded
    } catch let error as FountainError {
      throw error
    } catch {
      throw FountainError(
        .connection, "\(method.uppercased()) \(request.url!.absoluteString) failed: \(error)")
    }
  }

  public func data(
    _ method: String, _ path: String, query: [String: String?] = [:], body: JSONObject? = nil
  ) async throws -> JSONObject {
    let output = try await request(method, path, query: query, body: body.map(JSONValue.object))
    return output["data"]?.objectValue ?? [:]
  }

  public func list(_ path: String, query: [String: String?] = [:]) async throws -> [JSONObject] {
    let output = try await request("GET", path, query: query)
    return output["data"]?.arrayValue?.compactMap(\.objectValue) ?? []
  }

  func streamRequest(_ path: String, query: [String: String?], lastEventID: Int) throws
    -> URLRequest
  {
    var request = try makeRequest("GET", path, query: query, accept: "text/event-stream")
    request.timeoutInterval = fountainStreamTimeout
    if lastEventID > 0 {
      request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID")
    }
    return request
  }

  /// One request, awaited. See `RequestCancellation` for why
  /// `URLSession.data(for:)` is not used.
  private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let cancellation = RequestCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        let task = requests.dataTask(with: request) { data, response, error in
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
  }

  /// One streaming session for the life of the client, built on the first
  /// stream. Like `requests` it carries the caller's configuration, so a test
  /// that installs a `URLProtocol` reaches the stream too.
  var streamer: SSEStreamer {
    lock.lock()
    defer { lock.unlock() }
    if let openStreamer { return openStreamer }
    let created = SSEStreamer(configuration: transport)
    openStreamer = created
    return created
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
