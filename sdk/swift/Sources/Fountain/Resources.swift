import Foundation

public final class ResourceCollection: @unchecked Sendable {
  let http: FountainHTTPClient
  let resolver: ResourceResolver
  let path: String
  let what: String

  init(http: FountainHTTPClient, resolver: ResourceResolver, path: String, what: String) {
    self.http = http
    self.resolver = resolver
    self.path = path
    self.what = what
  }

  public func list(search: String? = nil) async throws -> [JSONObject] {
    try await http.list(path, query: ["search": search])
  }

  public func get(_ nameOrID: String) async throws -> JSONObject {
    let id = try await resourceID(nameOrID)
    return try await http.data("GET", "\(path)/\(id)")
  }

  public func create(_ input: JSONObject) async throws -> JSONObject {
    let output = try await http.data("POST", path, body: input)
    await resolver.forget(path)
    return output
  }

  public func update(_ nameOrID: String, patch: JSONObject) async throws -> JSONObject {
    let output = try await http.data(
      "PATCH", "\(path)/\(try await resourceID(nameOrID))", body: patch)
    await resolver.forget(path)
    return output
  }

  public func delete(_ nameOrID: String) async throws {
    _ = try await http.request("DELETE", "\(path)/\(try await resourceID(nameOrID))")
    await resolver.forget(path)
  }

  func resourceID(_ nameOrID: String) async throws -> String {
    guard
      let id = try await resolver.resolve(path: path, what: what, nameOrID: nameOrID)["id"]?
        .stringValue
    else {
      throw FountainError(.resolution, "Resolved \(what) did not include an id")
    }
    return id
  }
}

public final class Secrets: @unchecked Sendable {
  private let collection: ResourceCollection
  init(collection: ResourceCollection) { self.collection = collection }

  public func list(_ parent: String) async throws -> [JSONObject] {
    try await collection.http.list(
      "\(collection.path)/\(try await collection.resourceID(parent))/secrets")
  }

  public func set(_ parent: String, key: String, value: String) async throws -> JSONObject {
    try await collection.http.data(
      "POST", "\(collection.path)/\(try await collection.resourceID(parent))/secrets",
      body: ["key": .string(key), "value": .string(value)]
    )
  }

  public func setAll(_ parent: String, secrets: [String: String]) async throws -> [JSONObject] {
    var output: [JSONObject] = []
    for key in secrets.keys.sorted() {
      output.append(try await set(parent, key: key, value: secrets[key]!))
    }
    return output
  }

  public func delete(_ parent: String, key: String) async throws {
    _ = try await collection.http.request(
      "DELETE",
      "\(collection.path)/\(try await collection.resourceID(parent))/secrets/\(key.pathEncoded)"
    )
  }
}

public final class Environments: @unchecked Sendable {
  private let collection: ResourceCollection
  public let secrets: Secrets
  init(http: FountainHTTPClient, resolver: ResourceResolver) {
    let collection = ResourceCollection(
      http: http, resolver: resolver, path: "/api/environments", what: "environment")
    self.collection = collection
    self.secrets = Secrets(collection: collection)
  }
  public func list(search: String? = nil) async throws -> [JSONObject] {
    try await collection.list(search: search)
  }
  public func get(_ value: String) async throws -> JSONObject { try await collection.get(value) }
  public func create(_ input: JSONObject) async throws -> JSONObject {
    try await collection.create(input)
  }
  public func update(_ value: String, patch: JSONObject) async throws -> JSONObject {
    try await collection.update(value, patch: patch)
  }
  public func delete(_ value: String) async throws { try await collection.delete(value) }
}

public final class Vaults: @unchecked Sendable {
  private let collection: ResourceCollection
  public let secrets: Secrets
  init(http: FountainHTTPClient, resolver: ResourceResolver) {
    let collection = ResourceCollection(
      http: http, resolver: resolver, path: "/api/vaults", what: "vault")
    self.collection = collection
    self.secrets = Secrets(collection: collection)
  }
  public func list(search: String? = nil) async throws -> [JSONObject] {
    try await collection.list(search: search)
  }
  public func get(_ value: String) async throws -> JSONObject { try await collection.get(value) }
  public func create(_ input: JSONObject) async throws -> JSONObject {
    try await collection.create(input)
  }
  public func update(_ value: String, patch: JSONObject) async throws -> JSONObject {
    try await collection.update(value, patch: patch)
  }
  public func delete(_ value: String) async throws { try await collection.delete(value) }
}

public typealias Agents = ResourceCollection

public final class Connections: @unchecked Sendable {
  private let http: FountainHTTPClient
  public let providers: ConnectionProviders
  init(http: FountainHTTPClient) {
    self.http = http
    self.providers = ConnectionProviders(http: http)
  }
  public func list() async throws -> [JSONObject] { try await http.list("/api/connections") }
  public func get(_ id: String) async throws -> JSONObject {
    try await http.request("GET", "/api/connections/\(id.pathEncoded)").objectValue ?? [:]
  }
  public func delete(_ id: String) async throws {
    _ = try await http.request("DELETE", "/api/connections/\(id.pathEncoded)")
  }
}

public final class ConnectionProviders: @unchecked Sendable {
  private let http: FountainHTTPClient
  init(http: FountainHTTPClient) { self.http = http }
  public func list() async throws -> [JSONObject] {
    try await http.list("/api/connection-providers")
  }
  public func get(_ id: String) async throws -> JSONObject { try await raw("GET", id) }
  public func create(_ input: JSONObject) async throws -> JSONObject {
    try await http.request("POST", "/api/connection-providers", body: .object(input)).objectValue
      ?? [:]
  }
  public func update(_ id: String, patch: JSONObject) async throws -> JSONObject {
    try await raw("PATCH", id, body: patch)
  }
  public func delete(_ id: String) async throws {
    _ = try await http.request("DELETE", "/api/connection-providers/\(id.pathEncoded)")
  }
  public func discover(_ id: String) async throws -> JSONObject {
    try await http.request("POST", "/api/connection-providers/\(id.pathEncoded)/discover")
      .objectValue ?? [:]
  }
  private func raw(_ method: String, _ id: String, body: JSONObject? = nil) async throws
    -> JSONObject
  {
    try await http.request(
      method, "/api/connection-providers/\(id.pathEncoded)", body: body.map(JSONValue.object)
    ).objectValue ?? [:]
  }
}
