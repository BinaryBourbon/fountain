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
  private let session: URLSession

  public init(
    configuration: FountainConfiguration, timeout: TimeInterval = 30, session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.timeout = timeout
    self.session = session
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
      let (data, response) = try await session.data(for: request)
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

  var sessionConfiguration: URLSessionConfiguration { session.configuration }
}
