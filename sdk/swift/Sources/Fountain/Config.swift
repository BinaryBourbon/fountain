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

  public static func resolve(
    apiKey: String? = nil,
    baseURL: String? = nil,
    profile: String? = nil,
    appURL: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    credentialsText: String? = nil
  ) -> FountainConfiguration {
    let selectedProfile =
      nonempty(profile) ?? nonempty(environment["FOUNTAIN_PROFILE"]) ?? "default"
    let credentials: [String: String] = {
      if let credentialsText { return parseCredentials(credentialsText, profile: selectedProfile) }
      let path =
        nonempty(environment["FOUNTAIN_CREDENTIALS_FILE"])
        ?? NSString(string: "~/.fountain/credentials").expandingTildeInPath
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
      return parseCredentials(text, profile: selectedProfile)
    }()
    let key =
      nonempty(apiKey)
      ?? nonempty(environment["FOUNTAIN_API_KEY"])
      ?? nonempty(environment["FOUNTAIN_TOKEN"])
      ?? nonempty(credentials["api_key"])
      ?? ""
    let endpoint =
      nonempty(baseURL)
      ?? nonempty(environment["FOUNTAIN_BASE_URL"])
      ?? nonempty(credentials["base_url"])
      ?? fountainDefaultBaseURL
    let selectedApp =
      appURL == nil
      ? (nonempty(environment["FOUNTAIN_APP_URL"]) ?? fountainDefaultAppURL)
      : nonempty(appURL)
    guard let defaultBase = httpURL(fountainDefaultBaseURL) else {
      preconditionFailure("The built-in Fountain base URL is invalid")
    }
    let resolvedBase = httpURL(endpoint) ?? defaultBase
    let resolvedApp = selectedApp.flatMap(httpURL)
    return FountainConfiguration(
      baseURL: resolvedBase,
      apiKey: key,
      appURL: resolvedApp,
      parentConversationID: nonempty(environment["FOUNTAIN_CONVERSATION_ID"])
    )
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
