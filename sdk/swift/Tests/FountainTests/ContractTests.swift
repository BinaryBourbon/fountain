import Foundation
import Testing

private struct ContractProblem {
  let scenario: String
  let detail: String
}

private func contractFile(_ relativePath: String, from sourceFile: String) throws -> URL {
  var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
  while true {
    let candidate = relativePath.split(separator: "/").reduce(directory) {
      $0.appendingPathComponent(String($1))
    }
    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

    let parent = directory.deletingLastPathComponent()
    if parent.path == directory.path {
      throw NSError(
        domain: "FountainContractTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate \(relativePath) from \(sourceFile)"]
      )
    }
    directory = parent
  }
}

private func readJSONObject(_ url: URL) throws -> [String: Any] {
  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
  guard let object = value as? [String: Any] else {
    throw NSError(
      domain: "FountainContractTests",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Expected a JSON object in \(url.path)"])
  }
  return object
}

@Suite("ContractTests")
struct ContractTests {
  @Test func verifiesSDKContract() throws {
    let contract = try readJSONObject(
      contractFile("sdk/contract/contract.json", from: #filePath))
    let manifest = try readJSONObject(
      contractFile("sdk/contract/manifests/swift.json", from: #filePath))
    let contractOperations = contract["operations"] as? [String: Any] ?? [:]
    let contractSchemas = contract["schemas"] as? [String: Any] ?? [:]
    var problems: [ContractProblem] = []

    func fail(_ scenario: String, _ detail: String) {
      problems.append(ContractProblem(scenario: scenario, detail: detail))
    }

    // Operations
    for operation in manifest["operations"] as? [String] ?? [] {
      if contractOperations[operation] == nil {
        fail(
          "operation \(operation)",
          "the API no longer serves it. Update the client, or drop it from the manifest.")
      }
    }

    // Schemas and their fields
    let manifestSchemas = manifest["schemas"] as? [String: Any] ?? [:]
    for name in manifestSchemas.keys.sorted() {
      guard let declared = manifestSchemas[name] as? [String: Any] else { continue }
      guard let schema = contractSchemas[name] as? [String: Any] else {
        fail("schema \(name)", "the API no longer defines it.")
        continue
      }
      let properties = schema["properties"] as? [String: Any] ?? [:]

      func check(_ field: String, expectation: String) {
        guard let property = properties[field] as? [String: Any] else {
          fail(
            "\(name).\(field)",
            "the API no longer has this property. It has: \(properties.keys.sorted().joined(separator: ", "))"
          )
          return
        }
        if expectation == "required", property["required"] as? Bool != true {
          fail(
            "\(name).\(field)",
            "this client reads it as always present, but the API no longer requires it.")
        }
        if expectation == "optional", property["required"] as? Bool == true {
          fail("\(name).\(field)", "this client omits it, but the API now requires it.")
        }
      }

      for field in declared["required"] as? [String] ?? [] {
        check(field, expectation: "required")
      }
      for field in declared["optional"] as? [String] ?? [] {
        check(field, expectation: "optional")
      }
      for field in declared["fields"] as? [String] ?? [] {
        check(field, expectation: "present")
      }
    }

    // Enum values
    let manifestEnums = manifest["enums"] as? [String: Any] ?? [:]
    for path in manifestEnums.keys.sorted() {
      guard let declared = manifestEnums[path] else { continue }
      let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
      let name = parts.first ?? ""
      let field = parts.count > 1 ? parts[1] : ""
      let schema = contractSchemas[name] as? [String: Any]
      let properties = schema?["properties"] as? [String: Any]
      guard let property = properties?[field] as? [String: Any] else {
        fail("enum \(path)", "the API no longer has this property.")
        continue
      }
      guard let accepted = property["enum"] as? [String] else {
        fail("enum \(path)", "the API no longer constrains this property to an enum.")
        continue
      }
      let declaration = declared as? [String: Any]
      let values = declared as? [String] ?? declaration?["values"] as? [String] ?? []
      let missing = values.filter { !accepted.contains($0) }
      if !missing.isEmpty {
        fail(
          "enum \(path)",
          "this client handles \(missing.joined(separator: ", ")), which the API no longer accepts. "
            + "It now accepts: \(accepted.joined(separator: ", "))")
      }
      if declaration?["exhaustive"] as? Bool == true {
        let extra = accepted.filter { !values.contains($0) }
        if !extra.isEmpty {
          fail(
            "enum \(path)",
            "this client claims to handle every value but the API added: \(extra.joined(separator: ", "))"
          )
        }
      }
    }

    if !problems.isEmpty {
      let details = problems.map { "  \($0.scenario)\n      \($0.detail)" }.joined(
        separator: "\n\n")
      let message =
        "SDK contract check FAILED for swift (\(problems.count) problems)\n\n\(details)"
      Issue.record(Comment(rawValue: message))
    }
  }
}
