import Testing

@testable import FountainKit

@Suite struct SSEParserTests {
  @Test func parsesSimpleEvent() {
    var parser = SSEParser()
    let events = parser.feed(Array("data: hello\n\n".utf8))
    #expect(events == [ServerSentEvent(data: "hello")])
  }

  @Test func parsesFullFrame() {
    var parser = SSEParser()
    let events = parser.feed(Array("id: 42\nevent: turn/done\ndata: {\"ok\":true}\n\n".utf8))
    #expect(events == [ServerSentEvent(id: "42", event: "turn/done", data: "{\"ok\":true}")])
    #expect(parser.lastEventID == "42")
  }

  @Test func joinsMultipleDataLines() {
    var parser = SSEParser()
    let events = parser.feed(Array("data: line one\ndata: line two\n\n".utf8))
    #expect(events == [ServerSentEvent(data: "line one\nline two")])
  }

  @Test func dropsCommentHeartbeats() {
    var parser = SSEParser()
    let events = parser.feed(Array(": keep-alive\n\ndata: x\n\n".utf8))
    #expect(events == [ServerSentEvent(data: "x")])
  }

  @Test func handlesChunkSplitAnywhere() {
    let raw = "id: 7\nevent: stage\ndata: first\n\ndata: second\n\n"
    // Split the byte stream at every possible boundary; results must not change.
    let bytes = Array(raw.utf8)
    for split in 0...bytes.count {
      var parser = SSEParser()
      var events = parser.feed(bytes[..<split])
      events += parser.feed(bytes[split...])
      #expect(
        events == [
          ServerSentEvent(id: "7", event: "stage", data: "first"),
          ServerSentEvent(data: "second"),
        ], "failed at split \(split)")
    }
  }

  @Test func handlesCRLFAndBareCR() {
    var parser = SSEParser()
    let events = parser.feed(Array("data: a\r\n\r\ndata: b\r\rdata".utf8))
    #expect(events == [ServerSentEvent(data: "a"), ServerSentEvent(data: "b")])
  }

  @Test func retainsLastEventIDAcrossEvents() {
    var parser = SSEParser()
    _ = parser.feed(Array("id: 1\ndata: a\n\ndata: b\n\n".utf8))
    #expect(parser.lastEventID == "1")
  }

  @Test func blankRecordEmitsNothing() {
    var parser = SSEParser()
    let events = parser.feed(Array("\n\n\n".utf8))
    #expect(events.isEmpty)
  }

  @Test func fieldWithNoColonAndNoSpaceAfterColon() {
    var parser = SSEParser()
    let events = parser.feed(Array("data:tight\ndata\n\n".utf8))
    // "data" with no colon is a field with empty value.
    #expect(events == [ServerSentEvent(data: "tight\n")])
  }
}
