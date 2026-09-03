import Foundation

/// One server-sent event, as framed by the SSE spec.
public struct ServerSentEvent: Sendable, Equatable {
  public var id: String?
  public var event: String?
  public var data: String

  public init(id: String? = nil, event: String? = nil, data: String) {
    self.id = id
    self.event = event
    self.data = data
  }
}

/// Incremental SSE parser. Feed it raw bytes as they arrive; it emits complete
/// events at each blank-line record boundary. Comment lines (`:` heartbeats)
/// are dropped. The last seen `id:` is retained across events so a reconnect
/// can resume with `Last-Event-ID`.
public struct SSEParser: Sendable {
  private var buffer: [UInt8] = []
  private var dataLines: [String] = []
  private var eventType: String?
  private var eventID: String?

  /// The most recent `id:` seen on any event, for reconnects.
  public private(set) var lastEventID: String?

  public init() {}

  /// Consume a chunk of bytes, returning any events completed by it.
  public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
    buffer.append(contentsOf: bytes)
    var events: [ServerSentEvent] = []
    while let line = nextLine() {
      if let event = process(line: line) {
        events.append(event)
      }
    }
    return events
  }

  /// Extract the next complete line from the buffer, handling \n, \r\n and \r.
  private mutating func nextLine() -> String? {
    var index = 0
    while index < buffer.count {
      let byte = buffer[index]
      if byte == 0x0A {  // \n
        let line = String(decoding: buffer[..<index], as: UTF8.self)
        buffer.removeFirst(index + 1)
        return line
      }
      if byte == 0x0D {  // \r — may be \r\n split across chunks
        if index + 1 < buffer.count {
          let line = String(decoding: buffer[..<index], as: UTF8.self)
          let skip = buffer[index + 1] == 0x0A ? index + 2 : index + 1
          buffer.removeFirst(skip)
          return line
        }
        // \r at end of buffer: wait for the next chunk to see if \n follows.
        return nil
      }
      index += 1
    }
    return nil
  }

  /// Process one line; returns a completed event at a blank line.
  private mutating func process(line: String) -> ServerSentEvent? {
    if line.isEmpty {
      defer {
        dataLines = []
        eventType = nil
        eventID = nil
      }
      guard !dataLines.isEmpty || eventType != nil else { return nil }
      return ServerSentEvent(id: eventID, event: eventType, data: dataLines.joined(separator: "\n"))
    }
    if line.hasPrefix(":") { return nil }  // comment / heartbeat

    let field: Substring
    let value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      var v = line[line.index(after: colon)...]
      if v.hasPrefix(" ") { v = v.dropFirst() }
      value = v
    } else {
      field = line[...]
      value = ""
    }

    switch field {
    case "data":
      dataLines.append(String(value))
    case "event":
      eventType = String(value)
    case "id":
      // Per spec, an id containing NUL is ignored.
      if !value.contains("\u{0}") {
        eventID = String(value)
        lastEventID = String(value)
      }
    case "retry":
      break  // server-suggested retry interval; the stream layer owns backoff
    default:
      break  // unknown fields are ignored per spec
    }
    return nil
  }
}
