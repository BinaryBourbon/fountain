import Foundation
import Testing

@testable import FountainKit

@Suite struct BaseURLTests {
  @Test func acceptsAbsoluteHTTPURLs() throws {
    #expect(
      try FountainConfig.baseURL(from: "https://managoat.com").absoluteString
        == "https://managoat.com")
    #expect(
      try FountainConfig.baseURL(from: "http://localhost:4000").absoluteString
        == "http://localhost:4000")
    #expect(
      try FountainConfig.baseURL(from: " https://fountain.test/ ").absoluteString
        == "https://fountain.test")
    #expect(
      try FountainConfig.baseURL(from: "https://host/fountain//").absoluteString
        == "https://host/fountain")
  }

  /// The whole point: a URL we can't use must not become a *different*
  /// server. `localhost:4000` parses as scheme `localhost`, no host — and
  /// falling back to the hosted deployment would post a self-hosted key
  /// to managoat.com.
  @Test(arguments: ["localhost:4000", "managoat.com", "", "   ", "ftp://files.test", "not a url"])
  func rejectsAnythingElse(_ text: String) {
    #expect(throws: FountainError.self) {
      try FountainConfig.baseURL(from: text)
    }
  }

  @Test func environmentBaseURLThatIsNotAURLThrowsInsteadOfRetargeting() {
    #expect(throws: FountainError.self) {
      try FountainConfig.fromEnvironment(environment: [
        "FOUNTAIN_BASE_URL": "localhost:4000",
        "FOUNTAIN_API_KEY": "ftn_live_selfhosted",
        "FOUNTAIN_CREDENTIALS_FILE": "/nonexistent",
      ])
    }
  }

  @Test func environmentWithNoBaseURLUsesTheHostedDefault() throws {
    let config = try FountainConfig.fromEnvironment(environment: [
      "FOUNTAIN_API_KEY": "ftn_live_test",
      "FOUNTAIN_CREDENTIALS_FILE": "/nonexistent",
    ])
    #expect(config.baseURL == FountainConfig.defaultBaseURL)
    #expect(config.apiKey == "ftn_live_test")
  }

  /// A trailing slash on the configured base is a `//path` request without
  /// normalisation — which is a protocol-relative URL, not a path.
  @Test func trailingSlashOnTheConfiguredBaseDoesNotDoubleUp() async throws {
    let transport = FakeTransport(json: #"{"data": []}"#)
    let client = FountainClient(
      config: FountainConfig(baseURL: URL(string: "https://fountain.test/")!, apiKey: "k"),
      transport: transport
    )
    _ = try await client.agents.list()
    #expect(transport.lastRequest?.url?.absoluteString == "https://fountain.test/api/agents")
  }

  @Test func conversationURLPrefersTheConversationsApp() {
    let bare = FountainConfig(baseURL: URL(string: "https://fountain.test")!)
    #expect(bare.conversationURL("c1").absoluteString == "https://fountain.test/conversations/c1")

    let withApp = FountainConfig(
      baseURL: URL(string: "https://fountain.test")!,
      appURL: URL(string: "https://talk.fountain.test/")!
    )
    #expect(withApp.conversationURL("c1").absoluteString == "https://talk.fountain.test/#/c/c1")
  }
}
