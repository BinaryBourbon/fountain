import Foundation

public struct SandboxesResource: Sendable {
  let client: APIClient

  public func list(status: [SandboxStatus] = []) async throws -> [Sandbox] {
    try await client.data(
      .get, "/api/sandboxes",
      options: .init(query: [
        "status": status.isEmpty ? nil : status.map(\.rawValue).joined(separator: ",")
      ]))
  }

  public func get(_ id: String) async throws -> SandboxDetail {
    try await client.data(.get, "/api/sandboxes/\(id)")
  }

  /// Reset a persistent sandbox. Throws `sandbox_not_resettable` for
  /// ephemeral/terminated ones and 409 `sandbox_mid_turn` while busy.
  public func reset(_ id: String) async throws {
    try await client.send(.delete, "/api/sandboxes/\(id)", options: .init(timeout: 120))
  }
}

public struct RunnersResource: Sendable {
  let client: APIClient

  public func list() async throws -> [Runner] {
    try await client.data(.get, "/api/runners")
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/runners/\(id)")
  }
}

public struct AuthResource: Sendable {
  let client: APIClient

  /// Unenveloped — the cheapest check that a key works.
  public func me() async throws -> AuthMe {
    try await client.request(.get, "/api/auth/me")
  }

  public func apiKeys() async throws -> [APIKey] {
    try await client.data(.get, "/api/auth/api-keys")
  }

  /// Unenveloped; the only response that carries key material.
  public func createAPIKey(name: String) async throws -> CreatedAPIKey {
    try await client.request(.post, "/api/auth/api-keys", body: ["name": name])
  }

  public func revokeAPIKey(_ id: String) async throws {
    try await client.send(.delete, "/api/auth/api-keys/\(id)")
  }

  /// Revoke the presented bearer token (sign out of an OAuth session).
  public func revokeToken() async throws {
    try await client.send(.post, "/api/oauth/revoke")
  }
}

public struct AuditResource: Sendable {
  let client: APIClient

  /// Newest first; page backward by passing the last row's id as `before`.
  public func list(
    limit: Int = 100,
    before: Int? = nil,
    actionPrefix: String? = nil,
    resourceType: String? = nil
  ) async throws -> Page<[AuditEvent]> {
    let (data, _) = try await client.raw(
      .get, "/api/audit",
      options: .init(query: [
        "limit": String(limit),
        "before": before.map(String.init),
        "action_prefix": actionPrefix,
        "resource_type": resourceType,
      ]))
    let envelope = try APIClient.decode(Envelope<[AuditEvent]>.self, from: data)
    return Page(items: envelope.data, meta: envelope.meta)
  }
}

public struct SearchResource: Sendable {
  let client: APIClient

  public func search(
    _ query: String,
    limit: Int = 20,
    offset: Int = 0,
    agentID: String? = nil,
    conversationID: String? = nil
  ) async throws -> Page<[SearchHit]> {
    let (data, _) = try await client.raw(
      .get, "/api/search",
      options: .init(query: [
        "q": query,
        "limit": String(limit),
        "offset": offset > 0 ? String(offset) : nil,
        "agent_id": agentID,
        "conversation_id": conversationID,
      ]))
    let envelope = try APIClient.decode(Envelope<[SearchHit]>.self, from: data)
    return Page(items: envelope.data, meta: envelope.meta)
  }
}
