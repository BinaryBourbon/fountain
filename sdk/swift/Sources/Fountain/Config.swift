import Foundation

public let fountainDefaultBaseURL = "https://managoat.com"
public let fountainDefaultAppURL = "https://fountain-conversations.demo.managoat.com"

public struct FountainConfiguration: Equatable, Sendable {
  public let baseURL: URL
  public let apiKey: String
  public let appURL: URL?
  public let parentConversationID: String?

  public init(baseURL: URL, apiKey: String, appURL: URL?, parentConversationID: String? = nil) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.appURL = appURL
    self.parentConversationID = parentConversationID
  }

  public func conversationURL(_ id: String) -> URL {
    if let appURL {
      var components = URLComponents(url: appURL, resolvingAgainstBaseURL: false)
      if components?.path.isEmpty == true {
        components?.path = "/"
      } else if components?.path.hasSuffix("/") == false {
        components?.path.append("/")
      }
      components?.fragment = "/c/\(id)"
      return components?.url ?? appURL
    }
    return baseURL.appendingPathComponent("api/conversations/\(id)")
  }
}

public enum FountainConfig {
  public static func parseCredentials(_ text: String, profile: String) -> [String: String] {
    var section = ""
    var values: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \Character.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        continue
      }
      guard section == profile, let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2, let first = value.first, value.last == first,
        first == "\"" || first == "'"
      {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
      }
      values[key] = value
    }
    return values
  }

  /// Throws `FountainError(.validation, ...)` when a base or app URL that the
  /// caller supplied cannot be parsed. An earlier version fell back to the
  /// hosted Fountain, which sent the caller's API key to a host they never
  /// named: `baseURL: "localhost:4000"` has no scheme, so it parses to nothing.
  public static func resolve(
    apiKey: String? = nil,
    baseURL: String? = nil,
    profile: String? = nil,
    appURL: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    credentialsText: String? = nil
  ) throws -> FountainConfiguration {
    try resolve(
      apiKey: apiKey, baseURL: baseURL, profile: profile, appURL: appURL,
      environment: environment, credentialsText: credentialsText,
      readFile: { try? String(contentsOfFile: $0, encoding: .utf8) })
  }

  static func resolve(
    apiKey: String?,
    baseURL: String?,
    profile: String?,
    appURL: String?,
    environment: [String: String],
    credentialsText: String?,
    readFile: (String) -> String?
  ) throws -> FountainConfiguration {
    let selectedProfile =
      nonempty(profile) ?? nonempty(environment["FOUNTAIN_PROFILE"]) ?? "default"
    // Read the credentials file at most once, and only when an argument and the
    // environment have both missed. `??` evaluates its right side lazily, so a
    // caller that passes every value never touches the disk.
    var cache: [String: String]?
    func credentials() -> [String: String] {
      if let cache { return cache }
      let text =
        credentialsText
        ?? readFile(
          nonempty(environment["FOUNTAIN_CREDENTIALS_FILE"])
            ?? NSString(string: "~/.fountain/credentials").expandingTildeInPath)
      let values = text.map { parseCredentials($0, profile: selectedProfile) } ?? [:]
      cache = values
      return values
    }
    let key =
      nonempty(apiKey)
      ?? nonempty(environment["FOUNTAIN_API_KEY"])
      ?? nonempty(environment["FOUNTAIN_TOKEN"])
      ?? nonempty(credentials()["api_key"])
      ?? ""
    let endpoint =
      source(nonempty(baseURL), "the baseURL argument")
      ?? source(nonempty(environment["FOUNTAIN_BASE_URL"]), "FOUNTAIN_BASE_URL")
      ?? source(nonempty(credentials()["base_url"]), "base_url in the CLI credentials file")
      ?? (value: fountainDefaultBaseURL, origin: "the built-in default")
    let app =
      appURL == nil
      ? (source(nonempty(environment["FOUNTAIN_APP_URL"]), "FOUNTAIN_APP_URL")
        ?? (value: fountainDefaultAppURL, origin: "the built-in default"))
      : source(nonempty(appURL), "the appURL argument")
    return FountainConfiguration(
      baseURL: try url(endpoint, what: "Fountain base URL"),
      apiKey: key,
      appURL: try app.map { try url($0, what: "conversation app URL") },
      parentConversationID: nonempty(environment["FOUNTAIN_CONVERSATION_ID"])
    )
  }

  private static func source(_ value: String?, _ origin: String) -> (
    value: String, origin: String
  )? {
    value.map { (value: $0, origin: origin) }
  }

  private static func url(_ endpoint: (value: String, origin: String), what: String) throws -> URL {
    guard let url = httpURL(endpoint.value) else {
      throw FountainError(
        .validation,
        "\(endpoint.origin) is not a valid \(what): \(endpoint.value). Give a full URL with a "
          + "scheme and a host, such as https://fountain.example.com or http://localhost:4000.")
    }
    return url
  }

  private static func nonempty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func httpURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
      url.scheme == "http" || url.scheme == "https", url.host != nil
    else { return nil }
    return url
  }
}
