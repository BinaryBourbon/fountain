import Foundation

/// `/api/connections`: the account's OAuth connections and the providers
/// this deployment offers. Starting a connection is a browser flow
/// (`ConnectionProvider.connectURL`); deleting one revokes it.
public struct ConnectionsResource: Sendable {
  let client: APIClient

  public func list() async throws -> [Connection] {
    try await client.data(.get, "/api/connections")
  }

  public func providers() async throws -> [ConnectionProvider] {
    try await client.data(.get, "/api/connections/providers")
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/connections/\(id)")
  }
}
