import Foundation

/// Baseline set of encrypted env vars + runtime config attached to an agent.
public struct Environment: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String
  /// e.g. `{"apt": [...], "npm": [...]}`.
  public var packages: JSONValue?
  public var envVars: [String: String]?
  public var setupScript: String?
  public var networkingType: NetworkingType?
  public var networkingConfig: JSONValue?
  public var repositories: [JSONValue]?
  public var metadata: JSONValue?
  public var secretCount: Int?
  public var agentCount: Int?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, packages, repositories, metadata
    case envVars = "env_vars"
    case setupScript = "setup_script"
    case networkingType = "networking_type"
    case networkingConfig = "networking_config"
    case secretCount = "secret_count"
    case agentCount = "agent_count"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

public struct EnvironmentInput: Sendable, Encodable {
  public var name: String?
  public var packages: JSONValue?
  public var envVars: [String: String]?
  public var setupScript: String?
  public var networkingType: NetworkingType?
  public var networkingConfig: JSONValue?
  public var repositories: [JSONValue]?
  public var metadata: JSONValue?

  public init(
    name: String? = nil,
    packages: JSONValue? = nil,
    envVars: [String: String]? = nil,
    setupScript: String? = nil,
    networkingType: NetworkingType? = nil,
    networkingConfig: JSONValue? = nil,
    repositories: [JSONValue]? = nil,
    metadata: JSONValue? = nil
  ) {
    self.name = name
    self.packages = packages
    self.envVars = envVars
    self.setupScript = setupScript
    self.networkingType = networkingType
    self.networkingConfig = networkingConfig
    self.repositories = repositories
    self.metadata = metadata
  }

  enum CodingKeys: String, CodingKey {
    case name, packages, repositories, metadata
    case envVars = "env_vars"
    case setupScript = "setup_script"
    case networkingType = "networking_type"
    case networkingConfig = "networking_config"
  }
}

/// Free-floating bag of env-var overrides; wins on key collision at spawn.
public struct Vault: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var description: String?
  public var metadata: JSONValue?
  public var secretCount: Int?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, description, metadata
    case secretCount = "secret_count"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

public struct VaultInput: Sendable, Encodable {
  public var name: String?
  public var description: String?
  public var metadata: JSONValue?

  public init(name: String? = nil, description: String? = nil, metadata: JSONValue? = nil) {
    self.name = name
    self.description = description
    self.metadata = metadata
  }
}

/// A secret's key and timestamps. Values are write-only — the API never
/// returns one, and the UI should say so.
public struct Secret: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var key: String
  public var environmentID: String?
  public var vaultID: String?
  /// Vault secrets only; advisory.
  public var expiresAt: Date?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, key
    case environmentID = "environment_id"
    case vaultID = "vault_id"
    case expiresAt = "expires_at"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}
