import Foundation
import Testing

@testable import FountainKit

/// Read-only smoke against a real Fountain, using the same credential
/// resolution as the CLI (`~/.fountain/credentials`, `FOUNTAIN_API_KEY`).
/// Off by default so `swift test` is hermetic; run with:
///
///     FOUNTAIN_SMOKE=1 swift test --filter LiveSmokeTests
///
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOUNTAIN_SMOKE"] != nil))
struct LiveSmokeTests {
  /// Throwing, because a `FOUNTAIN_BASE_URL` that isn't a real URL is a
  /// failed smoke run, not a silent redirect to the hosted service.
  var client: FountainClient {
    get throws { FountainClient(config: try .fromEnvironment()) }
  }

  @Test func meAgentsAndCatalog() async throws {
    let client = try client
    let me = try await client.auth.me()
    #expect(!me.email.isEmpty)

    let agents = try await client.agents.list()
    #expect(!agents.isEmpty)

    let catalog = try await client.catalog()
    #expect(catalog.runtimes?.isEmpty == false)
  }

  @Test func conversationHistoryAndDrainStream() async throws {
    let client = try client
    let conversations = try await client.conversations.list()
    guard let conversation = conversations.first else { return }

    let page = try await client.conversations.events(conversation.id, limit: 25)
    #expect(page.meta != nil)

    var drained = 0
    for try await event in client.conversations.stream(
      conversation.id, StreamRequest(wait: false)
    ) {
      if case .log = event { drained += 1 }
      if drained >= 5 { break }
    }
    // A drain may legitimately be empty; the point is it completes and decodes.
  }

  @Test func teamRosterAndInfra() async throws {
    let client = try client
    _ = try await client.team.list()
    _ = try await client.runners.list()
    _ = try await client.sandboxes.list()
    _ = try await client.search.search("fountain", limit: 3)
    _ = try await client.audit.list(limit: 5)
  }
}
