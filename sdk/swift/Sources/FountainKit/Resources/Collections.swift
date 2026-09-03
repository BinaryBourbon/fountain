import Foundation

/// Agents: CRUD + versions + avatar.
public struct AgentsResource: Sendable {
  let client: APIClient

  public func list(search: String? = nil) async throws -> [Agent] {
    try await client.data(.get, "/api/agents", options: .init(query: ["search": search]))
  }

  public func get(_ id: String) async throws -> Agent {
    try await client.data(.get, "/api/agents/\(id)")
  }

  public func create(_ input: AgentInput) async throws -> Agent {
    try await client.data(.post, "/api/agents", body: input)
  }

  public func update(_ id: String, _ patch: AgentInput) async throws -> Agent {
    try await client.data(.patch, "/api/agents/\(id)", body: patch)
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/agents/\(id)")
  }

  public func versions(_ id: String) async throws -> [AgentVersion] {
    try await client.data(.get, "/api/agents/\(id)/versions")
  }

  public func version(_ id: String, _ version: Int) async throws -> AgentVersion {
    try await client.data(.get, "/api/agents/\(id)/versions/\(version)")
  }

  /// Avatar bytes + media type; nil when the agent has none.
  /// (`<img src>` can't send the bearer — always fetch through this.)
  public func avatar(_ id: String) async throws -> (Data, String)? {
    do {
      let (data, response) = try await client.raw(
        .get, "/api/agents/\(id)/avatar",
        options: .init(accept: "image/*")
      )
      let mediaType = response.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
      return (data, mediaType)
    } catch FountainError.notFound {
      return nil
    }
  }
}

/// Environments: CRUD + write-only secrets.
public struct EnvironmentsResource: Sendable {
  let client: APIClient

  public func list(search: String? = nil) async throws -> [Environment] {
    try await client.data(.get, "/api/environments", options: .init(query: ["search": search]))
  }

  public func get(_ id: String) async throws -> Environment {
    try await client.data(.get, "/api/environments/\(id)")
  }

  public func create(_ input: EnvironmentInput) async throws -> Environment {
    try await client.data(.post, "/api/environments", body: input)
  }

  public func update(_ id: String, _ patch: EnvironmentInput) async throws -> Environment {
    try await client.data(.patch, "/api/environments/\(id)", body: patch)
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/environments/\(id)")
  }

  /// Keys and timestamps only — values are write-only.
  public func secrets(_ id: String) async throws -> [Secret] {
    try await client.data(.get, "/api/environments/\(id)/secrets")
  }

  public func setSecret(_ id: String, key: String, value: String) async throws -> Secret {
    try await client.data(
      .post, "/api/environments/\(id)/secrets",
      body: ["key": key, "value": value]
    )
  }

  public func deleteSecret(_ id: String, key: String) async throws {
    try await client.send(.delete, "/api/environments/\(id)/secrets/\(encodePathComponent(key))")
  }
}

/// Vaults: CRUD + write-only secrets (with optional expiry).
public struct VaultsResource: Sendable {
  let client: APIClient

  public func list(search: String? = nil) async throws -> [Vault] {
    try await client.data(.get, "/api/vaults", options: .init(query: ["search": search]))
  }

  public func get(_ id: String) async throws -> Vault {
    try await client.data(.get, "/api/vaults/\(id)")
  }

  public func create(_ input: VaultInput) async throws -> Vault {
    try await client.data(.post, "/api/vaults", body: input)
  }

  public func update(_ id: String, _ patch: VaultInput) async throws -> Vault {
    try await client.data(.patch, "/api/vaults/\(id)", body: patch)
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/vaults/\(id)")
  }

  public func secrets(_ id: String) async throws -> [Secret] {
    try await client.data(.get, "/api/vaults/\(id)/secrets")
  }

  public func setSecret(_ id: String, key: String, value: String, expiresAt: String? = nil)
    async throws -> Secret
  {
    var body = ["key": key, "value": value]
    if let expiresAt { body["expires_at"] = expiresAt }
    return try await client.data(.post, "/api/vaults/\(id)/secrets", body: body)
  }

  public func deleteSecret(_ id: String, key: String) async throws {
    try await client.send(.delete, "/api/vaults/\(id)/secrets/\(encodePathComponent(key))")
  }
}

func encodePathComponent(_ value: String) -> String {
  value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}
