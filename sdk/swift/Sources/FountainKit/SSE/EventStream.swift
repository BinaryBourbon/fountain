import Foundation

/// One element of a Fountain SSE stream.
public enum StreamEvent: Sendable {
  /// A log event (`output` or `stage`), including the synthetic
  /// `stage: "server"` event that means the conversation server exited.
  case log(LogEvent)
  /// A change signal with no id: `team`, `schedule` or `conversations`.
  /// Re-list the named collection; these never disturb the resume cursor.
  case signal(String)
}

/// Options for the three SSE surfaces.
public struct StreamRequest: Sendable {
  /// Resume after this log-event id (sent as `Last-Event-ID` when > 0).
  public var after: Int
  /// Subset of `stdout, stderr, acp, stage`; empty means everything.
  public var streams: [LogStream]
  /// `false` drains buffered events and closes instead of tailing.
  public var wait: Bool
  public var maxRetries: Int
  public var retryDelay: TimeInterval

  public init(
    after: Int = 0,
    streams: [LogStream] = [],
    wait: Bool = true,
    maxRetries: Int = 5,
    retryDelay: TimeInterval = 0.5
  ) {
    self.after = after
    self.streams = streams
    self.wait = wait
    self.maxRetries = maxRetries
    self.retryDelay = retryDelay
  }
}

/// The one reconnecting SSE loop, shared by the conversation, team and
/// all-events streams. Fountain closes an idle stream after ~60s — that's a
/// normal reconnect, not an error. Backoff is linear (delay × attempt); a
/// 4xx is thrown immediately because it never self-heals.
enum EventStreamLoop {
  static func stream(
    client: APIClient,
    path: String,
    request: StreamRequest
  ) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var lastID = request.after
        var attempt = 0
        var query: [String: String?] = ["blocks": "true"]
        if !request.streams.isEmpty {
          query["streams"] = request.streams.map(\.rawValue).joined(separator: ",")
        }
        if !request.wait { query["wait"] = "false" }

        connect: while !Task.isCancelled {
          var options = RequestOptions(query: query)
          if lastID > 0 { options.headers["Last-Event-ID"] = String(lastID) }

          let byteStream: AsyncThrowingStream<Data, Error>
          do {
            let (response, bytes) = try await client.openStream(path, options: options)
            guard (200..<300).contains(response.statusCode) else {
              // Read what error body arrived, then decide.
              var body = Data()
              for try await chunk in bytes { body.append(chunk) }
              let error = APIClient.error(
                status: response.statusCode, data: body, response: response)
              attempt += 1
              if response.statusCode < 500 || attempt > request.maxRetries {
                continuation.finish(throwing: error)
                return
              }
              try await Task.sleep(
                nanoseconds: UInt64(max(0, request.retryDelay * Double(attempt) * 1_000_000_000)))
              continue connect
            }
            byteStream = bytes
          } catch {
            attempt += 1
            if Task.isCancelled || attempt > request.maxRetries {
              continuation.finish(throwing: error)
              return
            }
            try await Task.sleep(
              nanoseconds: UInt64(max(0, request.retryDelay * Double(attempt) * 1_000_000_000)))
            continue connect
          }

          attempt = 0
          var parser = SSEParser()
          do {
            for try await chunk in byteStream {
              for sse in parser.feed(chunk) {
                if let id = sse.id.flatMap(Int.init), id > 0 { lastID = id }
                if let event = decode(sse) {
                  continuation.yield(event)
                }
              }
              if Task.isCancelled { break }
            }
          } catch {
            attempt += 1
            if Task.isCancelled || attempt > request.maxRetries {
              continuation.finish(throwing: error)
              return
            }
            try await Task.sleep(
              nanoseconds: UInt64(max(0, request.retryDelay * Double(attempt) * 1_000_000_000)))
            continue connect
          }

          // Clean close: a drain ends here; a tail reconnects.
          if !request.wait || Task.isCancelled { break }
          attempt += 1
          if attempt > request.maxRetries { break }
          try await Task.sleep(nanoseconds: UInt64(max(0, request.retryDelay) * 1_000_000_000))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func decode(_ sse: ServerSentEvent) -> StreamEvent? {
    switch sse.event {
    case "team", "schedule", "conversations":
      return .signal(sse.event!)
    default:
      break
    }
    guard let data = sse.data.data(using: .utf8),
      var event = try? APIClient.decoder.decode(LogEvent.self, from: data)
    else { return nil }
    if event.id == nil, let id = sse.id.flatMap(Int.init), id > 0 {
      event.id = id
    }
    return .log(event)
  }
}

extension AsyncThrowingStream where Element == StreamEvent, Failure == Error {
  /// Just the log events.
  public var logEvents: AsyncCompactMapSequence<Self, LogEvent> {
    compactMap {
      if case .log(let event) = $0 { return event }
      return nil
    }
  }
}
