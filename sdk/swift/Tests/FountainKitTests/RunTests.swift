import Foundation
import Testing

@testable import FountainKit

/// The behaviour the cross-language conformance scenarios don't describe:
/// how `Run` shares one followed turn between several readers.
@Suite struct RunTests {
  private static let stream = """
    id: 1
    event: stage
    data: {"id":1,"kind":"stage","stage":"turn","state":"started","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\"}"}

    id: 2
    event: output
    data: {"id":2,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"tool_use","name":"grep"}]}

    id: 3
    event: output
    data: {"id":3,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"text","body":"Found it."}]}

    id: 4
    event: stage
    data: {"id":4,"kind":"stage","stage":"turn","state":"done","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\", \\"stop_reason\\": \\"end_turn\\"}"}


    """

  private func startedRun() async throws -> Run {
    let transport = FakeTransport([
      .init(json: #"{"data": {"id": "c1", "status": "running", "runtime": "claude"}}"#),
      .init(json: Self.stream),
      .init(json: #"{"data": {"id": "c1", "status": "idle", "runtime": "claude"}}"#),
    ])
    return try await FountainClient.fake(transport).run("hello", agent: "a1")
  }

  @Test func valueIsTheSameAnswerHoweverOftenItIsAsked() async throws {
    let run = try await startedRun()
    let first = try await run.value()
    let second = try await run.value()

    #expect(first == second)
    #expect(first.text == "Found it.")
    #expect(first.toolsUsed == ["grep"])
    #expect(first.state == .done)
    #expect(first.status == .idle)
    #expect(first.turnNumber == 1)
    #expect(!first.isFailure)
  }

  /// A view that subscribes after the turn finished still gets the whole
  /// transcript — a late reader must not see an empty stream.
  @Test func aLateSubscriberGetsEveryEventReplayed() async throws {
    let run = try await startedRun()
    _ = try await run.value()

    var seen: [String] = []
    for try await event in run.events {
      switch event {
      case .conversation(let conversation, _): seen.append("conversation:\(conversation.id)")
      case .turnStart(let number, _): seen.append("start:\(number)")
      case .tool(let name, _): seen.append("tool:\(name)")
      case .text(let text): seen.append("text:\(text)")
      case .turnEnd(let state, _, _): seen.append("end:\(state.rawValue)")
      default: break
      }
    }
    #expect(seen == ["conversation:c1", "start:1", "tool:grep", "text:Found it.", "end:done"])
  }

  /// Two readers of one run see the same turn, and neither starts a second
  /// stream — the app tails a conversation in a window and a menu bar item
  /// at once.
  @Test func twoSubscribersSeeTheSameTurn() async throws {
    let run = try await startedRun()

    async let first = collectText(run)
    async let second = collectText(run)
    let (left, right) = try await (first, second)

    #expect(left == "Found it.")
    #expect(right == left)
    #expect(try await run.value().text == left)
  }

  /// The sandbox can go away mid-turn, and then the turn-end never comes.
  /// Waiting for it is the hang this avoids.
  @Test func aConversationThatDiesUnderTheTurnEndsTheRun() async throws {
    let dying = """
      id: 1
      event: stage
      data: {"id":1,"kind":"stage","stage":"turn","state":"started","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\"}"}

      id: 2
      event: output
      data: {"id":2,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"text","body":"Half an answer"}]}

      id: 3
      event: stage
      data: {"id":3,"kind":"stage","stage":"sandbox","state":"failed","stream":"stage","data":"{\\"message\\": \\"the sandbox went away\\"}"}


      """
    let failed = #"{"data": {"id": "c1", "status": "failed", "runtime": "claude"}}"#
    let transport = FakeTransport([
      .init(json: #"{"data": {"id": "c1", "status": "running", "runtime": "claude"}}"#),
      .init(json: dying),
      .init(json: failed),  // the check that the conversation really died
      .init(json: failed),  // the final status read
    ])

    let result = try await FountainClient.fake(transport).run("hello", agent: "a1").value()
    #expect(result.state == .failed)
    #expect(result.text == "Half an answer")
    #expect(result.reason == "sandbox/failed: the sandbox went away")
    #expect(result.status == .failed)
    #expect(result.isFailure)
  }

  private func collectText(_ run: Run) async throws -> String {
    var text = ""
    for try await event in run.events {
      if case .text(let chunk) = event { text += chunk }
    }
    return text
  }
}
