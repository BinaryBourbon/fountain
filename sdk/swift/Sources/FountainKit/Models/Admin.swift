import Foundation

/// One account as an admin sees it (`/api/admin/users`).
public struct AdminUser: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var email: String
  public var role: UserRole?
  public var emailVerified: Bool?
  public var emailVerifiedAt: Date?
  public var suspended: Bool?
  public var suspendedAt: Date?
  public var comped: Bool?
  public var creditBalanceCents: Int?
  public var hasStripeCustomer: Bool?
  public var activeSandboxes: Int?
  public var maxConcurrentSandboxes: Int?
  public var sandboxLimitOverride: Int?
  public var lastActivityAt: Date?
  public var onboardingCompletedAt: Date?
  public var insertedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, email, role, suspended, comped
    case emailVerified = "email_verified"
    case emailVerifiedAt = "email_verified_at"
    case suspendedAt = "suspended_at"
    case creditBalanceCents = "credit_balance_cents"
    case hasStripeCustomer = "has_stripe_customer"
    case activeSandboxes = "active_sandboxes"
    case maxConcurrentSandboxes = "max_concurrent_sandboxes"
    case sandboxLimitOverride = "sandbox_limit_override"
    case lastActivityAt = "last_activity_at"
    case onboardingCompletedAt = "onboarding_completed_at"
    case insertedAt = "inserted_at"
  }
}

/// `/api/admin/users` is the one endpoint with page-number pagination:
/// `meta` is `{page, per_page, total}`, not a cursor.
public struct AdminUserPage: Sendable, Decodable {
  public var users: [AdminUser]
  public var page: Int
  public var perPage: Int
  public var total: Int

  enum CodingKeys: String, CodingKey {
    case data, meta
  }

  enum MetaKeys: String, CodingKey {
    case page, total
    case perPage = "per_page"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    users = try container.decode([AdminUser].self, forKey: .data)
    let meta = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
    page = try meta.decode(Int.self, forKey: .page)
    perPage = try meta.decode(Int.self, forKey: .perPage)
    total = try meta.decode(Int.self, forKey: .total)
  }

  public var hasMore: Bool { page * perPage < total }
}

/// A live sandbox across any tenant (`/api/admin/sandboxes`).
public struct AdminSandbox: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var provider: SandboxProvider?
  public var status: SandboxStatus?
  public var spriteName: String?
  public var userID: String?
  public var userEmail: String?
  public var conversationCount: Int?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, provider, status
    case spriteName = "sprite_name"
    case userID = "user_id"
    case userEmail = "user_email"
    case conversationCount = "conversation_count"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

/// One entry in the privilege trail (`/api/admin/events`): which admin did
/// what to which account.
public struct AdminEvent: Sendable, Decodable, Identifiable, Hashable {
  public var id: Int?
  public var eventType: String
  public var actorUserID: String?
  public var targetUserID: String?
  public var metadata: JSONValue?
  public var insertedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, metadata
    case eventType = "event_type"
    case actorUserID = "actor_user_id"
    case targetUserID = "target_user_id"
    case insertedAt = "inserted_at"
  }
}
