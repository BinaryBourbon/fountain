import Foundation
import Testing

@testable import FountainKit

@Suite struct TurnFollowerTests {
  func stage(_ state: String, turnNumber: Int = 1, turnID: String = "t1", meta: String = "")
    -> LogEvent
  {
    let extra = meta.isEmpty ? "" : ",\(meta)"
    // The stage event's `data` field is a JSON-encoded string; let
    // JSONSerialization do the escaping.
    let inner = #"{"turn_id":"\#(turnID)","turn_number":\#(turnNumber)\#(extra)}"#
    let payload: [String: Any] = [
      "id": 1, "kind": "stage", "stage": "turn", "state": state, "data": inner,
    ]
    let bytes = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(LogEvent.self, from: bytes)
  }

  func output(_ blocks: String, stream: String = "acp", turnID: String? = "t1") -> LogEvent {
    let turn = turnID.map { "\"\($0)\"" } ?? "null"
    return try! JSONDecoder().decode(
      LogEvent.self,
      from: Data(
        """
        {"id":2,"kind":"output","stream":"\(stream)","turn_id":\(turn),"blocks":[\(blocks)]}
        """.utf8))
  }

  @Test func followsOneTurnStartToEnd() {
    var follower = TurnFollower(turnNumber: 1)
    let starts = follower.apply(stage("started"))
    #expect(follower.started)
    #expect(follower.turnID == "t1")
    guard case .turnStart = starts.first else {
      Issue.record("expected turnStart")
      return
    }

    _ = follower.apply(output(#"{"kind":"text","body":"Hello"}"#))
    let ends = follower.apply(stage("done", meta: #""exit_code":0,"stop_reason":"end_turn""#))
    #expect(follower.finished)
    #expect(follower.state == .done)
    #expect(follower.exitCode == 0)
    #expect(follower.reason == "end_turn")
    #expect(follower.text == "Hello")
    guard case .turnEnd = ends.last else {
      Issue.record("expected turnEnd")
      return
    }
  }

  @Test func acpChunksConcatenateStdoutParagraphs() {
    var follower = TurnFollower(turnNumber: 1)
    _ = follower.apply(stage("started"))
    _ = follower.apply(output(#"{"kind":"text","body":"Hel"}"#))
    _ = follower.apply(output(#"{"kind":"text","body":"lo"}"#))
    #expect(follower.text == "Hello")

    var legacy = TurnFollower(turnNumber: 1)
    _ = legacy.apply(stage("started"))
    _ = legacy.apply(output(#"{"kind":"text","body":"one"}"#, stream: "stdout"))
    _ = legacy.apply(output(#"{"kind":"text","body":"two"}"#, stream: "stdout"))
    #expect(legacy.text == "one\n\ntwo")
  }

  @Test func textAfterToolStartsNewParagraph() {
    var follower = TurnFollower(turnNumber: 1)
    _ = follower.apply(stage("started"))
    _ = follower.apply(output(#"{"kind":"text","body":"Looking."}"#))
    _ = follower.apply(output(#"{"kind":"tool_use","id":"c1","name":"Bash"}"#))
    _ = follower.apply(output(#"{"kind":"text","body":"Found it."}"#))
    #expect(follower.text == "Looking.\n\nFound it.")
    #expect(follower.tools == ["Bash"])
  }

  @Test func dropsOutputFromOtherTurns() {
    var follower = TurnFollower(turnNumber: 2)
    // Tail of an older turn before ours starts: dropped.
    _ = follower.apply(output(#"{"kind":"text","body":"stale"}"#, turnID: "t1"))
    _ = follower.apply(stage("started", turnNumber: 2, turnID: "t2"))
    // Someone else's turn while ours runs: dropped.
    _ = follower.apply(output(#"{"kind":"text","body":"foreign"}"#, turnID: "t9"))
    _ = follower.apply(output(#"{"kind":"text","body":"ours"}"#, turnID: "t2"))
    #expect(follower.text == "ours")
  }

  @Test func resultBlockCountsOnlyWhenNothingElseDid() {
    var withText = TurnFollower(turnNumber: 1)
    _ = withText.apply(stage("started"))
    _ = withText.apply(output(#"{"kind":"text","body":"answer"}"#))
    _ = withText.apply(output(#"{"kind":"result","body":"summary"}"#))
    #expect(withText.text == "answer")

    var resultOnly = TurnFollower(turnNumber: 1)
    _ = resultOnly.apply(stage("started"))
    _ = resultOnly.apply(output(#"{"kind":"result","body":"summary"}"#))
    #expect(resultOnly.text == "summary")
  }

  @Test func thinkingIsEmittedButNotPartOfTheAnswer() {
    var follower = TurnFollower(turnNumber: 1)
    _ = follower.apply(stage("started"))
    let events = follower.apply(output(#"{"kind":"thinking","body":"hmm"}"#))
    #expect(follower.text.isEmpty)
    #expect(events.contains { if case .thinking("hmm") = $0 { true } else { false } })
  }

  @Test func ignoresStageEventsForOtherTurnNumbers() {
    var follower = TurnFollower(turnNumber: 3)
    _ = follower.apply(stage("started", turnNumber: 2, turnID: "t2"))
    #expect(!follower.started)
    _ = follower.apply(stage("done", turnNumber: 2, turnID: "t2"))
    #expect(!follower.finished)
  }
}
