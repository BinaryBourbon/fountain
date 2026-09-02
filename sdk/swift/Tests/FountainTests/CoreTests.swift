import Foundation
import Testing

@testable import Fountain

@Test func configurationPrecedenceAndConversationURL() throws {
  let config = try FountainConfig.resolve(
    apiKey: " argument ", baseURL: "https://api.example.test/", profile: "work",
    environment: ["FOUNTAIN_API_KEY": "environment"],
    credentialsText: "[work]\napi_key = credentials\n"
  )
  #expect(config.apiKey == "argument")
  #expect(config.baseURL.absoluteString == "https://api.example.test")
  #expect(
    config.conversationURL("abc").absoluteString
      == "https://fountain-conversations.demo.managoat.com/#/c/abc")
  let nested = FountainConfiguration(
    baseURL: config.baseURL, apiKey: "key", appURL: URL(string: "https://app.example.test/base"))
  #expect(nested.conversationURL("abc").absoluteString == "https://app.example.test/base/#/c/abc")
}

@Test func jsonValueLiteralsAndSafeIntegerRoundTrip() throws {
  let value: JSONValue = ["id": 9_007_199_254_740_993, "ready": true, "tags": ["swift"]]
  let encoded = try JSONEncoder().encode(value)
  let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
  #expect(decoded["id"]?.intValue == 9_007_199_254_740_993)
  #expect(decoded == value)
}

@Test func sseParserHandlesCommentsCRLFAndMultilineData() throws {
  let messages = parseSSE(
    ": heartbeat\r\nid: 7\r\nevent: output\r\ndata: {\"kind\":\r\ndata: \"output\"}\r\n\r\n")
  #expect(messages.count == 1)
  let message = try #require(messages.first)
  #expect(message.id == "7")
  #expect(message.event == "output")
  #expect(message.data.joined(separator: "\n") == "{\"kind\":\n\"output\"}")
}

@Test func turnFollowerFoldsChunksToolsAndPermission() {
  let follower = TurnFollower(turnNumber: 1)
  _ = follower.apply([
    "kind": "stage", "stage": "turn", "state": "started",
    "data": ["turn_number": 1, "turn_id": "turn-1"],
  ])
  let outputs = follower.apply([
    "kind": "output", "stream": "acp", "turn_id": "turn-1",
    "blocks": [
      ["kind": "text", "body": "Hello"], ["kind": "text", "body": " world"],
      ["kind": "tool_use", "name": "shell"], ["kind": "text", "body": "Done"],
      [
        "kind": "permission_request", "request_id": "p/1", "name": "shell",
        "options": [["option_id": "yes", "kind": "allow_once"]],
      ],
    ],
  ])
  #expect(follower.text == "Hello world\n\nDone")
  #expect(follower.toolsUsed == ["shell"])
  #expect(
    outputs.contains {
      if case .permission(let request, _) = $0 { return request.requestID == "p/1" }
      return false
    })
}

@Test func anUnparseableBaseURLThrowsAndNamesWhereItCameFrom() throws {
  // A base URL without a scheme used to fall back to the hosted Fountain, which
  // put the caller's API key on a host they never named.
  func message(_ body: () throws -> FountainConfiguration) -> String {
    do {
      let config = try body()
      Issue.record("Expected a validation error, resolved \(config.baseURL) instead")
      return ""
    } catch let error as FountainError {
      #expect(error.kind == .validation)
      return error.message
    } catch {
      Issue.record("Expected a FountainError, got \(error)")
      return ""
    }
  }

  let fromArgument = message {
    try FountainConfig.resolve(baseURL: "localhost:4000", environment: [:], credentialsText: "")
  }
  #expect(fromArgument.contains("the baseURL argument"))
  #expect(fromArgument.contains("localhost:4000"))
  #expect(!fromArgument.contains(fountainDefaultBaseURL))

  let fromEnvironment = message {
    try FountainConfig.resolve(
      environment: ["FOUNTAIN_BASE_URL": "fountain.internal:4000"], credentialsText: "")
  }
  #expect(fromEnvironment.contains("FOUNTAIN_BASE_URL"))

  let fromCredentials = message {
    try FountainConfig.resolve(
      environment: [:], credentialsText: "[default]\nbase_url = ftp://files.example.test\n")
  }
  #expect(fromCredentials.contains("CLI credentials file"))

  let fromApp = message {
    try FountainConfig.resolve(
      baseURL: "https://api.example.test", appURL: "app.example.test", environment: [:],
      credentialsText: "")
  }
  #expect(fromApp.contains("conversation app URL"))

  // An empty app URL still means "this deployment has no conversation app".
  let none = try FountainConfig.resolve(
    baseURL: "https://api.example.test", appURL: "", environment: [:], credentialsText: "")
  #expect(none.appURL == nil)
}

@Test func credentialsAreReadOnceAndOnlyWhenSomethingIsMissing() throws {
  let file = "[default]\napi_key = from-file\nbase_url = https://from-file.example.test\n"

  var passedEverything = 0
  let passed = try FountainConfig.resolve(
    apiKey: "secret", baseURL: "https://api.example.test", profile: nil, appURL: nil,
    environment: [:], credentialsText: nil,
    readFile: { _ in
      passedEverything += 1
      return file
    })
  #expect(passed.apiKey == "secret")
  #expect(passed.baseURL.absoluteString == "https://api.example.test")
  #expect(passedEverything == 0)

  var passedNothing = 0
  let resolved = try FountainConfig.resolve(
    apiKey: nil, baseURL: nil, profile: nil, appURL: nil, environment: [:], credentialsText: nil,
    readFile: { _ in
      passedNothing += 1
      return file
    })
  #expect(resolved.apiKey == "from-file")
  #expect(resolved.baseURL.absoluteString == "https://from-file.example.test")
  #expect(passedNothing == 1)
}
