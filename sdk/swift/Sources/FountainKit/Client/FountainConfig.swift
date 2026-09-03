import Foundation

/// Connection settings for one Fountain deployment.
public struct FountainConfig: Sendable, Equatable {
  /// The hosted instance; any self-hosted Fountain works by overriding this.
  public static let defaultBaseURL = URL(string: "https://managoat.com")!

  public var baseURL: URL
  public var apiKey: String?
  /// Where transcript deep links point (the conversations app).
  /// `nil` falls back to the API itself.
  public var appURL: URL?
  /// Default timeout for ordinary calls. Streams are never timed out.
  public var timeout: TimeInterval
  /// Stamped as `X-Fountain-Parent-Conversation-Id` so conversations this
  /// client opens become children (set when running inside a sandbox).
  public var parentConversationID: String?

  public init(
    baseURL: URL = FountainConfig.defaultBaseURL,
    apiKey: String? = nil,
    appURL: URL? = nil,
    timeout: TimeInterval = 30,
    parentConversationID: String? = nil
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.appURL = appURL
    self.timeout = timeout
    self.parentConversationID = parentConversationID
  }

  /// Where a human reads this transcript: the conversations app when the
  /// deployment names one, else the API itself.
  public func conversationURL(_ id: String) -> URL {
    if let appURL,
      let url = URL(string: "\(appURL.absoluteString.trimmingTrailingSlashes())/#/c/\(id)")
    {
      return url
    }
    return baseURL.appendingPathComponent("conversations/\(id)")
  }

  /// Parse a base URL a human or the environment supplied. Throws rather
  /// than substituting a different host: `localhost:4000` parses to a URL
  /// with no host, and quietly falling back to the hosted deployment would
  /// send a self-hosted key to a server the caller never named.
  public static func baseURL(from string: String) throws -> URL {
    let trimmed = string.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes()
    guard !trimmed.isEmpty,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { throw FountainError.invalidBaseURL(string) }
    return url
  }

  /// Resolve from the same environment the CLI and TS SDK read:
  /// `FOUNTAIN_API_KEY` / `FOUNTAIN_TOKEN`, `FOUNTAIN_BASE_URL`,
  /// `FOUNTAIN_CONVERSATION_ID`, and `~/.fountain/credentials`.
  /// Throws `invalidBaseURL` when a URL was named but is unusable.
  public static func fromEnvironment(
    profile: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> FountainConfig {
    let profileName = firstNonEmpty(profile, environment["FOUNTAIN_PROFILE"]) ?? "default"
    let file = CredentialsFile.read(
      path: environment["FOUNTAIN_CREDENTIALS_FILE"],
      profile: profileName
    )
    let apiKey = firstNonEmpty(
      environment["FOUNTAIN_API_KEY"],
      environment["FOUNTAIN_TOKEN"],
      file["api_key"]
    )
    let named = firstNonEmpty(environment["FOUNTAIN_BASE_URL"], file["base_url"])
    return FountainConfig(
      baseURL: try named.map(baseURL(from:)) ?? defaultBaseURL,
      apiKey: apiKey,
      parentConversationID: firstNonEmpty(environment["FOUNTAIN_CONVERSATION_ID"])
    )
  }

  private static func firstNonEmpty(_ candidates: String?...) -> String? {
    for candidate in candidates {
      if let trimmed = candidate?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }
}

extension String {
  func trimmingTrailingSlashes() -> String {
    var s = Substring(self)
    while s.hasSuffix("/") { s = s.dropLast() }
    return String(s)
  }
}

/// Reader for `~/.fountain/credentials` — INI-ish `[profile]` sections with
/// `key = value` lines; `#`/`;` comments; matching quotes stripped.
/// A missing or unreadable file contributes nothing.
enum CredentialsFile {
  static func read(path: String?, profile: String) -> [String: String] {
    let url: URL =
      if let path, !path.isEmpty {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      } else {
        FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".fountain/credentials")
      }
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    return parse(content, profile: profile)
  }

  static func parse(_ content: String, profile: String) -> [String: String] {
    var values: [String: String] = [:]
    var inSection = false
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        inSection = String(line.dropFirst().dropLast()) == profile
        continue
      }
      guard inSection, let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      for quote in ["\"", "'"]
      where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
        value = String(value.dropFirst().dropLast())
      }
      values[key] = value
    }
    return values
  }
}
