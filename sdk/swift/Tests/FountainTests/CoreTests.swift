import Foundation
import Testing

@testable import Fountain

@Test func configurationPrecedenceAndConversationURL() {
  let config = FountainConfig.resolve(
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

@Test func sdkVersionMatchesServerVersion() throws {
  let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let mix = try String(contentsOf: packageRoot.appendingPathComponent("mix.exs"), encoding: .utf8)
  let expression = try NSRegularExpression(pattern: #"version: \"([0-9]+\.[0-9]+\.[0-9]+)\""#)
  let fullRange = NSRange(mix.startIndex..<mix.endIndex, in: mix)
  let match = try #require(expression.firstMatch(in: mix, range: fullRange))
  let versionRange = try #require(Range(match.range(at: 1), in: mix))
  #expect(String(mix[versionRange]) == fountainSDKVersion)
}

@Test func sseParserHandlesCommentsCRLFAndMultilineData() {
  let messages = parseSSE(
    ": heartbeat\r\nid: 7\r\nevent: output\r\ndata: {\"kind\":\r\ndata: \"output\"}\r\n\r\n")
  #expect(messages.count == 1)
  #expect(messages[0].id == "7")
  #expect(messages[0].event == "output")
  #expect(messages[0].data.joined(separator: "\n") == "{\"kind\":\n\"output\"}")
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
