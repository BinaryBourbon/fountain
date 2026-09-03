import Foundation

/// The computer a conversation runs on. Several conversations may share one.
public struct Sandbox: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var spriteName: String?
  public var status: SandboxStatus?
  public var agentID: String?
  public var environmentID: String?
  public var vaultID: String?
  public var mode: SandboxMode?
  public var url: String?
  public var checkpoint: Checkpoint?
  public var provider: SandboxProvider?
  public var runner: RunnerRef?

  public struct Checkpoint: Sendable, Decodable, Hashable {
    public var id: String?
    public var at: Date?
  }

  /// The self-hosted runner a sandbox lives on, when provider == .runner.
  public struct RunnerRef: Sendable, Decodable, Hashable {
    public var id: String?
    public var name: String?
    public var hostname: String?
    public var online: Bool?
    public var path: String?
  }

  enum CodingKeys: String, CodingKey {
    case id, status, mode, url, checkpoint, provider, runner
    case spriteName = "sprite_name"
    case agentID = "agent_id"
    case environmentID = "environment_id"
    case vaultID = "vault_id"
  }
}

/// `GET /api/sandboxes/:id` — the sandbox plus its conversations.
public struct SandboxDetail: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var spriteName: String?
  public var status: SandboxStatus?
  public var agentID: String?
  public var environmentID: String?
  public var vaultID: String?
  public var mode: SandboxMode?
  public var url: String?
  public var checkpoint: Sandbox.Checkpoint?
  public var provider: SandboxProvider?
  public var runner: Sandbox.RunnerRef?
  public var conversations: [SandboxConversation]?
  public var insertedAt: Date?
  public var lastResumedAt: Date?

  public struct SandboxConversation: Sendable, Decodable, Identifiable, Hashable {
    public var id: String
    public var status: ConversationStatus?
    public var title: String?
    public var runtime: Runtime?
    public var midTurn: Bool?
    public var insertedAt: Date?

    enum CodingKeys: String, CodingKey {
      case id, status, title, runtime
      case midTurn = "mid_turn"
      case insertedAt = "inserted_at"
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, status, mode, url, checkpoint, provider, runner, conversations
    case spriteName = "sprite_name"
    case agentID = "agent_id"
    case environmentID = "environment_id"
    case vaultID = "vault_id"
    case insertedAt = "inserted_at"
    case lastResumedAt = "last_resumed_at"
  }
}

/// A self-hosted runner daemon that dials out to this Fountain.
public struct Runner: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var hostname: String?
  public var os: String?
  public var arch: String?
  public var version: String?
  public var root: String?
  public var online: Bool
  public var connectedAt: Date?
  public var lastSeenAt: Date?
  public var createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, hostname, os, arch, version, root, online
    case connectedAt = "connected_at"
    case lastSeenAt = "last_seen_at"
    case createdAt = "created_at"
  }
}
