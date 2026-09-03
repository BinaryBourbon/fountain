import Foundation

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
    let (byteStream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw FountainError.transport(URLError(.badServerResponse))
    }
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      let task = Task {
        do {
          // Coalesce bytes, flushing at each newline so SSE records
          // are delivered as soon as they are complete.
          var chunk = Data()
          for try await byte in byteStream {
            chunk.append(byte)
            if byte == 0x0A || chunk.count >= 4096 {
              continuation.yield(chunk)
              chunk = Data()
            }
          }
          if !chunk.isEmpty { continuation.yield(chunk) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (http, stream)
  }
}
