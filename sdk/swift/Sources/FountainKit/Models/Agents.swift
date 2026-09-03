import Foundation

/// A named, re-runnable agent config — model, runtime, skills, MCP servers,
/// optional environment.
public struct Agent: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var description: String?
  public var system: String?
  public var model: String
  public var runtime: Runtime
  public var acp: Bool?
  public var sandboxProvider: SandboxProvider?
  public var sandboxMode: SandboxMode?
  public var environmentID: String?
  /// Tool key → verdict (`auto_allow | ask | auto_deny`), plus a `default` key.
  public var permissionPolicy: [String: String]?
  public var skills: [Skill]?
  public var mcpServers: JSONValue?
  public var metadata: JSONValue?
  /// `nil` = any vault, `[]` = none, a list = allowlist. Same for environments.
  public var allowedVaultIDs: [String]?
  public var allowedEnvironmentIDs: [String]?
  public var conversationCount: Int?
  public var avatarMediaType: String?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, description, system, model, runtime, acp, skills, metadata
    case sandboxProvider = "sandbox_provider"
    case sandboxMode = "sandbox_mode"
    case environmentID = "environment_id"
    case permissionPolicy = "permission_policy"
    case mcpServers = "mcp_servers"
    case allowedVaultIDs = "allowed_vault_ids"
    case allowedEnvironmentIDs = "allowed_environment_ids"
    case conversationCount = "conversation_count"
    case avatarMediaType = "avatar_media_type"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

/// Inline (`name` + `content`) or GitHub-sourced (`source` + optional `ref`).
/// Exactly one of `content`/`source` is set.
public struct Skill: Sendable, Codable, Hashable {
  public var name: String?
  public var content: String?
  public var source: String?
  public var ref: String?

  public init(
    name: String? = nil, content: String? = nil, source: String? = nil, ref: String? = nil
  ) {
    self.name = name
    self.content = content
    self.source = source
    self.ref = ref
  }
}

/// One saved version of an agent's config (1-based, monotonic).
public struct AgentVersion: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var agentID: String
  public var version: Int
  public var config: JSONValue?
  public var insertedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, version, config
    case agentID = "agent_id"
    case insertedAt = "inserted_at"
  }
}

/// Create/update payload for an agent. Fields left nil are omitted, so the
/// same type serves POST and PATCH.
public struct AgentInput: Sendable, Encodable {
  public var name: String?
  public var description: String?
  public var system: String?
  public var model: String?
  public var runtime: Runtime?
  public var sandboxProvider: SandboxProvider?
  public var sandboxMode: SandboxMode?
  public var environmentID: String?
  public var permissionPolicy: [String: String]?
  public var skills: [Skill]?
  public var mcpServers: JSONValue?
  public var metadata: JSONValue?
  public var allowedVaultIDs: [String]?
  public var allowedEnvironmentIDs: [String]?

  public init(
    name: String? = nil,
    description: String? = nil,
    system: String? = nil,
    model: String? = nil,
    runtime: Runtime? = nil,
    sandboxProvider: SandboxProvider? = nil,
    sandboxMode: SandboxMode? = nil,
    environmentID: String? = nil,
    permissionPolicy: [String: String]? = nil,
    skills: [Skill]? = nil,
    mcpServers: JSONValue? = nil,
    metadata: JSONValue? = nil,
    allowedVaultIDs: [String]? = nil,
    allowedEnvironmentIDs: [String]? = nil
  ) {
    self.name = name
    self.description = description
    self.system = system
    self.model = model
    self.runtime = runtime
    self.sandboxProvider = sandboxProvider
    self.sandboxMode = sandboxMode
    self.environmentID = environmentID
    self.permissionPolicy = permissionPolicy
    self.skills = skills
    self.mcpServers = mcpServers
    self.metadata = metadata
    self.allowedVaultIDs = allowedVaultIDs
    self.allowedEnvironmentIDs = allowedEnvironmentIDs
  }

  enum CodingKeys: String, CodingKey {
    case name, description, system, model, runtime, skills, metadata
    case sandboxProvider = "sandbox_provider"
    case sandboxMode = "sandbox_mode"
    case environmentID = "environment_id"
    case permissionPolicy = "permission_policy"
    case mcpServers = "mcp_servers"
    case allowedVaultIDs = "allowed_vault_ids"
    case allowedEnvironmentIDs = "allowed_environment_ids"
  }
}
