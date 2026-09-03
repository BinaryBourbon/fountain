import Foundation

/// `GET /api/auth/me` — the cheapest check that a key works.
public struct AuthMe: Sendable, Decodable, Hashable {
  public var id: String
  public var email: String
  public var role: UserRole?
  public var emailVerified: Bool?
  public var onboardingState: String?
  public var onboardingCompleted: Bool?
  /// Null when billing is off on this deployment.
  public var comped: Bool?
  /// Gates secret-bindings, connections and the egress log.
  public var brokered: Bool?
  /// When the presented key expires (OAuth tokens do).
  public var expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, email, role, comped, brokered
    case emailVerified = "email_verified"
    case onboardingState = "onboarding_state"
    case onboardingCompleted = "onboarding_completed"
    case expiresAt = "expires_at"
  }
}

public struct APIKey: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var prefix: String?
  public var scopes: [String]?
  public var createdAt: Date?
  public var lastUsedAt: Date?
  public var expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, prefix, scopes
    case createdAt = "created_at"
    case lastUsedAt = "last_used_at"
    case expiresAt = "expires_at"
  }
}

/// The one response that ever carries key material.
public struct CreatedAPIKey: Sendable, Decodable, Hashable {
  public var id: String
  public var name: String?
  public var key: String
  public var prefix: String?
  public var createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, key, prefix
    case createdAt = "created_at"
  }
}

public struct AuditEvent: Sendable, Decodable, Identifiable, Hashable {
  /// Integer id: the backward-pagination cursor (`before`).
  public var id: Int
  public var insertedAt: Date?
  /// `ui | api | sprite | system`.
  public var actor: String?
  /// e.g. `vault.secret.write`.
  public var action: String
  public var resourceType: String?
  public var resourceID: String?
  public var metadata: JSONValue?
  public var requestIP: String?

  enum CodingKeys: String, CodingKey {
    case id, actor, action, metadata
    case insertedAt = "inserted_at"
    case resourceType = "resource_type"
    case resourceID = "resource_id"
    case requestIP = "request_ip"
  }
}

public struct SearchHit: Sendable, Decodable, Hashable {
  public var kind: SearchHitKind
  public var conversationID: String
  public var agentID: String?
  public var turnID: String?
  public var turnNumber: Int?
  public var snippet: String?
  public var ts: Date?

  enum CodingKeys: String, CodingKey {
    case kind, snippet, ts
    case conversationID = "conversation_id"
    case agentID = "agent_id"
    case turnID = "turn_id"
    case turnNumber = "turn_number"
  }
}

/// `GET /api/catalog` — what this deployment offers.
public struct Catalog: Sendable, Decodable {
  public var runtimes: [String]?
  /// runtime → suggested `provider/model` ids (suggestions, not an allowlist).
  public var models: [String: [String]]?
  public var modelProviders: [String]?
  public var sandboxProviders: SandboxProviders?
  public var packageManagers: [String]?
  public var avatar: AvatarOptions?
  /// Where the conversation and team apps live; either may be null.
  public var apps: Apps?

  public struct SandboxProviders: Sendable, Decodable {
    public var enabled: [String]?
    public var `default`: String?
  }

  public struct AvatarOptions: Sendable, Decodable {
    public var bases: [String]?
    public var moods: [String]?
  }

  public struct Apps: Sendable, Decodable {
    public var conversations: String?
    public var team: String?
  }

  enum CodingKeys: String, CodingKey {
    case runtimes, models, avatar, apps
    case modelProviders = "model_providers"
    case sandboxProviders = "sandbox_providers"
    case packageManagers = "package_managers"
  }
}

/// One result row from `POST /api/apply`.
public struct ApplyResult: Sendable, Decodable, Hashable {
  public var kind: String
  public var name: String
  /// `created | updated | error`.
  public var action: String
  public var errors: JSONValue?
  public var secrets: [SecretResult]?

  public struct SecretResult: Sendable, Decodable, Hashable {
    public var key: String
    public var action: String
    public var errors: JSONValue?
  }
}
