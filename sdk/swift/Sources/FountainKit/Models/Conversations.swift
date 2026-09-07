import Foundation

/// Per-turn controls. The server refuses unsupported controls and wider allowances.
public struct ExecutionLimits: Sendable, Codable, Hashable {
  public var wallTimeSeconds: Int?
  public var maxModelTurns: Int?
  public var maxEstimatedCostUSD: Double?

  public init(
    wallTimeSeconds: Int? = nil, maxModelTurns: Int? = nil, maxEstimatedCostUSD: Double? = nil
  ) {
    self.wallTimeSeconds = wallTimeSeconds
    self.maxModelTurns = maxModelTurns
    self.maxEstimatedCostUSD = maxEstimatedCostUSD
  }

  enum CodingKeys: String, CodingKey {
    case wallTimeSeconds = "wall_time_seconds"
    case maxModelTurns = "max_model_turns"
    case maxEstimatedCostUSD = "max_estimated_cost_usd"
  }
}

/// A single run of an agent inside a sandbox: turns, log events, a status
/// lifecycle.
public struct Conversation: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var title: String?
  public var sandboxID: String?
  public var sandbox: Sandbox?
  public var agentID: String?
  public var agentVersionID: String?
  /// Resolved only on list/get; null where a conversation is embedded.
  public var agentVersion: Int?
  public var vaultID: String?
  public var environmentID: String?
  public var permissionPolicy: [String: String]?
  public var executionLimits: ExecutionLimits?
  public var runtime: Runtime
  public var acp: Bool?
  public var status: ConversationStatus
  public var runtimeSessionID: String?
  public var source: ConversationSource?
  public var parentConversationID: String?
  public var channelID: String?
  public var turnCount: Int?
  public var firstPrompt: String?
  public var lastActiveAt: Date?
  public var lastReadAt: Date?
  public var unread: Bool?
  public var usageTotal: Usage?
  public var insertedAt: Date?
  public var updatedAt: Date?
  /// Team history only: whether this is the teammate's current thread.
  public var current: Bool?

  enum CodingKeys: String, CodingKey {
    case id, title, sandbox, runtime, acp, status, source, unread, current
    case sandboxID = "sandbox_id"
    case agentID = "agent_id"
    case agentVersionID = "agent_version_id"
    case agentVersion = "agent_version"
    case vaultID = "vault_id"
    case environmentID = "environment_id"
    case permissionPolicy = "permission_policy"
    case executionLimits = "execution_limits"
    case runtimeSessionID = "runtime_session_id"
    case parentConversationID = "parent_conversation_id"
    case channelID = "channel_id"
    case turnCount = "turn_count"
    case firstPrompt = "first_prompt"
    case lastActiveAt = "last_active_at"
    case lastReadAt = "last_read_at"
    case usageTotal = "usage_total"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

public struct UsageAccounting: Sendable, Decodable, Hashable {
  public var version: Int
  public var source: String
  public var scope: String
  public var completeness: String
}

public struct Usage: Sendable, Decodable, Hashable {
  public var input: Int?
  public var output: Int?
  public var cacheRead: Int?
  public var cacheWrite: Int?
  public var accounting: UsageAccounting?

  enum CodingKeys: String, CodingKey {
    case input, output, accounting
    case cacheRead = "cache_read"
    case cacheWrite = "cache_write"
  }
}

public struct Turn: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var turnNumber: Int
  public var prompt: String
  public var status: TurnStatus
  public var origin: TurnOrigin?
  public var exitCode: Int?
  public var limitReason: String?
  public var startedAt: Date?
  public var endedAt: Date?
  public var insertedAt: Date?
  public var imageCount: Int?
  /// Null while running, unreported, or on legacy turns.
  public var usage: Usage?

  enum CodingKeys: String, CodingKey {
    case id, prompt, status, origin, usage
    case turnNumber = "turn_number"
    case exitCode = "exit_code"
    case limitReason = "limit_reason"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case insertedAt = "inserted_at"
    case imageCount = "image_count"
  }
}

public struct ConversationTreeNode: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var source: ConversationSource?
  public var status: ConversationStatus?
  public var parentID: String?

  enum CodingKeys: String, CodingKey {
    case id, source, status
    case parentID = "parent_id"
  }
}

/// Base64 image attachment for a prompt.
public struct ImageInput: Sendable, Encodable {
  public var data: String
  public var mediaType: String

  public init(data: String, mediaType: String) {
    self.data = data
    self.mediaType = mediaType
  }

  enum CodingKeys: String, CodingKey {
    case data
    case mediaType = "media_type"
  }
}

/// `POST /api/conversations` body.
public struct ConversationCreateRequest: Sendable, Encodable {
  public var agentID: String
  public var prompt: String?
  public var title: String?
  public var vaultID: String?
  public var environmentID: String?
  public var permissionPolicy: [String: String]?
  public var executionLimits: ExecutionLimits?
  public var images: [ImageInput]?
  public var spriteName: String?
  public var sandboxMode: SandboxMode?
  public var sandboxID: String?
  public var channelID: String?
  /// With `channelID`: never resume, always open a new conversation
  /// (stealing the channel binding).
  public var fresh: Bool?

  public init(
    agentID: String,
    prompt: String? = nil,
    title: String? = nil,
    vaultID: String? = nil,
    environmentID: String? = nil,
    permissionPolicy: [String: String]? = nil,
    executionLimits: ExecutionLimits? = nil,
    images: [ImageInput]? = nil,
    spriteName: String? = nil,
    sandboxMode: SandboxMode? = nil,
    sandboxID: String? = nil,
    channelID: String? = nil,
    fresh: Bool? = nil
  ) {
    self.agentID = agentID
    self.prompt = prompt
    self.title = title
    self.vaultID = vaultID
    self.environmentID = environmentID
    self.permissionPolicy = permissionPolicy
    self.executionLimits = executionLimits
    self.images = images
    self.spriteName = spriteName
    self.sandboxMode = sandboxMode
    self.sandboxID = sandboxID
    self.channelID = channelID
    self.fresh = fresh
  }

  enum CodingKeys: String, CodingKey {
    case prompt, title, images, fresh
    case agentID = "agent_id"
    case vaultID = "vault_id"
    case environmentID = "environment_id"
    case permissionPolicy = "permission_policy"
    case executionLimits = "execution_limits"
    case spriteName = "sprite_name"
    case sandboxMode = "sandbox_mode"
    case sandboxID = "sandbox_id"
    case channelID = "channel_id"
  }
}
