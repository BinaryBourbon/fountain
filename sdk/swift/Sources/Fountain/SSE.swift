import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct SSEMessage {
  var id: String?
  var event = "message"
  var data: [String] = []
}

func parseSSE(_ text: String) -> [SSEMessage] {
  var messages: [SSEMessage] = []
  var current = SSEMessage()
  func flush() {
    if !current.data.isEmpty || current.id != nil { messages.append(current) }
    current = SSEMessage()
  }
  for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
    if line.isEmpty {
      flush()
      continue
    }
    if line.hasPrefix(":") { continue }
    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(parts[0])
    var value = parts.count == 2 ? String(parts[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    switch field {
    case "id": current.id = value
    case "event": current.event = value
    case "data": current.data.append(value)
    default: break
    }
  }
  flush()
  return messages
}

func decodeSSEMessage(_ message: SSEMessage) -> JSONObject? {
  let raw = message.data.joined(separator: "\n")
  guard let data = raw.data(using: .utf8),
    var object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
  else { return nil }
  if let id = message.id.flatMap(Int.init), id > 0 { object["id"] = .integer(id) }
  if object["kind"] == nil, message.event == "output" || message.event == "stage" {
    object["kind"] = .string(message.event)
  }
  return object
}

func streamPath(
  http: FountainHTTPClient, path: String, after: Int = 0, streams: String? = nil,
  wait: Bool = true, blocks: Bool = false, maxRetries: Int = 5, retryDelay: TimeInterval = 0.5
) -> AsyncThrowingStream<JSONObject, Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      var lastID = after
      var attempt = 0
      while !Task.isCancelled {
        do {
          let request = try http.streamRequest(
            path,
            query: [
              "streams": streams, "wait": wait ? nil : "false", "blocks": blocks ? "true" : nil,
            ], lastEventID: lastID)
          for try await item in SSEConnection.stream(
            request: request, configuration: http.sessionConfiguration)
          {
            switch item {
            case .opened:
              attempt = 0
            case .event(let event):
              if let id = event["id"]?.intValue { lastID = max(lastID, id) }
              continuation.yield(event)
            }
          }
          if !wait { break }
          attempt += 1
          if attempt > maxRetries { break }
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
          break
        } catch let error as FountainError where error.status > 0 && error.status < 500 {
          throw error
        } catch {
          attempt += 1
          if attempt > maxRetries { throw error }
        }
        try await Task.sleep(
          nanoseconds: UInt64(retryDelay * Double(max(1, attempt)) * 1_000_000_000))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    Task { do { try await task.value } catch { continuation.finish(throwing: error) } }
  }
}

func streamEvents(
  http: FountainHTTPClient, conversationID: String, after: Int = 0,
  streams: String? = nil, wait: Bool = true, maxRetries: Int = 5
) -> AsyncThrowingStream<JSONObject, Error> {
  streamPath(
    http: http, path: "/api/conversations/\(conversationID)/stream", after: after,
    streams: streams, wait: wait, blocks: true, maxRetries: maxRetries
  )
}

/// URLSessionDataDelegate is used instead of URLSession.AsyncBytes because the
/// latter is unavailable in FoundationNetworking on Linux.
private enum SSEItem: Sendable {
  case opened
  case event(JSONObject)
}

private final class SSEConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let continuation: AsyncThrowingStream<SSEItem, Error>.Continuation
  private let lock = NSLock()
  private var response: HTTPURLResponse?
  private var buffer = Data()
  private var errorBody = Data()
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var finished = false

  static func stream(request: URLRequest, configuration: URLSessionConfiguration)
    -> AsyncThrowingStream<SSEItem, Error>
  {
    AsyncThrowingStream { continuation in
      let connection = SSEConnection(continuation: continuation)
      let session = URLSession(
        configuration: configuration, delegate: connection, delegateQueue: nil)
      connection.session = session
      let task = session.dataTask(with: request)
      connection.task = task
      continuation.onTermination = { _ in connection.cancel() }
      task.resume()
    }
  }

  init(continuation: AsyncThrowingStream<SSEItem, Error>.Continuation) {
    self.continuation = continuation
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    self.response = response as? HTTPURLResponse
    if let response = self.response, (200..<300).contains(response.statusCode) {
      continuation.yield(.opened)
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    if let status = response?.statusCode, !(200..<300).contains(status) {
      errorBody.append(data)
      return
    }
    buffer.append(data)
    drainCompleteMessages()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    if !buffer.isEmpty {
      emit(buffer)
      buffer.removeAll()
    }
    let response = self.response
    let body = errorBody
    lock.unlock()
    defer { session.finishTasksAndInvalidate() }
    if let error {
      continuation.finish(throwing: error)
      return
    }
    if let response, !(200..<300).contains(response.statusCode) {
      let decoded =
        body.isEmpty
        ? nil
        : ((try? JSONDecoder().decode(JSONValue.self, from: body))
          ?? .string(String(decoding: body, as: UTF8.self)))
      let request = task.originalRequest
      guard let url = response.url ?? request?.url else {
        continuation.finish(
          throwing: FountainError(
            .api, "HTTP \(response.statusCode) opening SSE stream", status: response.statusCode,
            body: decoded))
        return
      }
      continuation.finish(
        throwing: fountainError(
          status: response.statusCode, body: decoded, method: request?.httpMethod ?? "GET",
          url: url, headers: response.allHeaderFields
        ))
      return
    }
    continuation.finish()
  }

  private func drainCompleteMessages() {
    while let boundary = nextBoundary(in: buffer) {
      let chunk = buffer.prefix(boundary.index)
      buffer.removeFirst(boundary.index + boundary.length)
      emit(Data(chunk))
    }
  }

  private func emit(_ data: Data) {
    for message in parseSSE(String(decoding: data, as: UTF8.self)) {
      if let event = decodeSSEMessage(message) { continuation.yield(.event(event)) }
    }
  }

  private func cancel() {
    lock.lock()
    let alreadyFinished = finished
    finished = true
    lock.unlock()
    if !alreadyFinished {
      task?.cancel()
      session?.invalidateAndCancel()
    }
  }
}

private func nextBoundary(in data: Data) -> (index: Int, length: Int)? {
  let lf = data.range(of: Data([10, 10])).map {
    data.distance(from: data.startIndex, to: $0.lowerBound)
  }
  let crlf = data.range(of: Data([13, 10, 13, 10])).map {
    data.distance(from: data.startIndex, to: $0.lowerBound)
  }
  switch (lf, crlf) {
  case (.none, .none): return nil
  case (.some(let index), .none): return (index, 2)
  case (.none, .some(let index)): return (index, 4)
  case (.some(let left), .some(let right)): return left < right ? (left, 2) : (right, 4)
  }
}
