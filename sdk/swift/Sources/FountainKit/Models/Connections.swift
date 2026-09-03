import Foundation

/// An OAuth connection the account holds (Gmail, Microsoft, …). An agent
/// mounts one as an MCP server with `{"connection": "<id>"}` in
/// `mcp_servers`; the platform injects the live token server-side.
public struct Connection: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var provider: String
  public var status: ConnectionStatus?
  public var accountEmail: String?
  public var envKey: String?
  public var scopes: [String]?
  public var expiresAt: Date?
  public var createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, provider, status, scopes
    case accountEmail = "account_email"
    case envKey = "env_key"
    case expiresAt = "expires_at"
    case createdAt = "created_at"
  }
}

public struct ConnectionStatus: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let active: Self = "active"
  public static let expired: Self = "expired"
  public static let revoked: Self = "revoked"
}

/// A provider this deployment can connect (only `configured` ones can
/// actually start an OAuth dance, via `connectURL` in the browser).
public struct ConnectionProvider: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String?
  public var slug: String?
  public var configured: Bool?
  public var envKey: String?
  public var mcpURL: String?
  public var connectURL: String?

  enum CodingKeys: String, CodingKey {
    case id, name, slug, configured
    case envKey = "env_key"
    case mcpURL = "mcp_url"
    case connectURL = "connect_url"
  }
}
