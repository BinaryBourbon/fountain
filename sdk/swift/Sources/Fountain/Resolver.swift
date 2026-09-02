import Foundation

actor ResourceResolver {
  private let http: FountainHTTPClient
  private var cache: [String: [JSONObject]] = [:]

  init(http: FountainHTTPClient) { self.http = http }

  func clear() { cache.removeAll() }
  func forget(_ path: String) { cache[path] = nil }

  func resolve(path: String, what: String, nameOrID: String) async throws -> JSONObject {
    let wanted = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else {
      throw FountainError(.resolution, "\(what) is required (a name or id)")
    }
    if UUID(uuidString: wanted) != nil {
      return cache[path]?.first(where: { $0["id"]?.stringValue == wanted }) ?? [
        "id": .string(wanted)
      ]
    }
    let items: [JSONObject]
    if let cached = cache[path] {
      items = cached
    } else {
      items = try await http.list(path)
      cache[path] = items
    }
    if let exactID = items.first(where: { $0["id"]?.stringValue == wanted }) { return exactID }
    let exact = items.filter {
      $0["name"]?.stringValue?.localizedCaseInsensitiveCompare(wanted) == .orderedSame
    }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 {
      throw FountainError(
        .resolution,
        "More than one \(what) is named \(wanted). Use an id: \(exact.compactMap { $0["id"]?.stringValue }.joined(separator: ", "))"
      )
    }
    let prefix = items.filter {
      $0["name"]?.stringValue?.lowercased().hasPrefix(wanted.lowercased()) == true
    }
    if prefix.count == 1 { return prefix[0] }
    if prefix.count > 1 {
      throw FountainError(
        .resolution,
        "\(wanted) matches more than one \(what): \(prefix.compactMap { $0["name"]?.stringValue ?? $0["id"]?.stringValue }.joined(separator: ", "))"
      )
    }
    let names = items.compactMap { $0["name"]?.stringValue ?? $0["id"]?.stringValue }.sorted()
      .joined(separator: ", ")
    throw FountainError(
      .resolution,
      "No \(what) named \(wanted). On this account: \(names.isEmpty ? "(none)" : names)")
  }

  func resolveID(path: String, what: String, nameOrID: String?) async throws -> String? {
    guard let nameOrID else { return nil }
    return try await resolve(path: path, what: what, nameOrID: nameOrID)["id"]?.stringValue
  }
}
