import Foundation

/// One row of a conversation's log feed. `id` is a global monotonic integer:
/// the pagination cursor on `/events` and the `Last-Event-ID` on the streams.
public struct LogEvent: Sendable, Decodable, Identifiable, Hashable {
  public var id: Int?
  public var kind: EventKind
  /// `stdout`/`stderr`/`acp` for output events; empty for stage events.
  public var stream: LogStream?
  /// Raw output text, or JSON-encoded metadata for stage events.
  public var data: String?
  /// Stage events: `provision`, `setup`, `turn`, `reattach`, `sandbox`,
  /// `terminate`, or the synthetic `server`.
  public var stage: String?
  public var state: EventState?
  public var durationMS: Int?
  public var turnID: String?
  public var ts: Date?
  /// Only present with `?blocks=true` (absent, not null, without it).
  public var blocks: [Block]?
  /// Team/events streams only.
  public var conversationID: String?
  public var agentID: String?

  enum CodingKeys: String, CodingKey {
    case id, kind, stream, data, stage, state, ts, blocks
    case durationMS = "duration_ms"
    case turnID = "turn_id"
    case conversationID = "conversation_id"
    case agentID = "agent_id"
  }

  /// Decoded stage metadata (the `data` field of a stage event is JSON).
  public var stageData: JSONValue? {
    guard kind == .stage, let data, let bytes = data.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: bytes)
  }
}

/// One parsed block of agent output — what `?blocks=true` folds every runtime
/// dialect into. Open-shaped: unknown keys are preserved in `extra`.
public struct Block: Sendable, Decodable, Hashable {
  public var kind: BlockKind
  public var body: String?
  public var summary: String?
  /// tool_use / permission_request: the tool name.
  public var name: String?
  /// tool_use: the call id; tool_result pairs on `toolID`.
  public var id: String?
  public var toolID: String?
  public var raw: String?
  public var isError: Bool?
  /// permission_request only.
  public var requestID: String?
  public var options: [PermissionOption]?
  /// Everything the known fields didn't claim.
  public var extra: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case kind, body, summary, name, id, raw, options
    case toolID = "tool_id"
    case isError = "error"
    case requestID = "request_id"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(BlockKind.self, forKey: .kind)
    body = try? container.decodeIfPresent(String.self, forKey: .body)
    summary = try? container.decodeIfPresent(String.self, forKey: .summary)
    name = try? container.decodeIfPresent(String.self, forKey: .name)
    id = try? container.decodeIfPresent(String.self, forKey: .id)
    toolID = try? container.decodeIfPresent(String.self, forKey: .toolID)
    raw = try? container.decodeIfPresent(String.self, forKey: .raw)
    isError = try? container.decodeIfPresent(Bool.self, forKey: .isError)
    requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)
    options = try? container.decodeIfPresent([PermissionOption].self, forKey: .options)

    let known = Set([
      "kind", "body", "summary", "name", "id", "tool_id", "raw", "error", "request_id", "options",
    ])
    let open = try decoder.container(keyedBy: AnyCodingKey.self)
    var extras: [String: JSONValue] = [:]
    for key in open.allKeys where !known.contains(key.stringValue) {
      extras[key.stringValue] = try? open.decode(JSONValue.self, forKey: key)
    }
    extra = extras
  }
}

/// One offered answer to a permission request. Never synthesise one the agent
/// did not offer — the server rejects unknown options.
public struct PermissionOption: Sendable, Decodable, Hashable {
  public var optionID: String?
  /// `allow_once | allow_always | reject_once | reject_always` (open set).
  public var kind: String?
  public var name: String?
  public var extra: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case optionID = "optionId"
    case optionIDSnake = "option_id"
    case kind, name
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Both spellings appear in the wild.
    optionID =
      (try? container.decodeIfPresent(String.self, forKey: .optionID))
      ?? (try? container.decodeIfPresent(String.self, forKey: .optionIDSnake))
    kind = try? container.decodeIfPresent(String.self, forKey: .kind)
    name = try? container.decodeIfPresent(String.self, forKey: .name)

    let known = Set(["optionId", "option_id", "kind", "name"])
    let open = try decoder.container(keyedBy: AnyCodingKey.self)
    var extras: [String: JSONValue] = [:]
    for key in open.allKeys where !known.contains(key.stringValue) {
      extras[key.stringValue] = try? open.decode(JSONValue.self, forKey: key)
    }
    extra = extras
  }
}

/// An answerable permission request extracted from a `permission_request`
/// block. `nil` when the block has no request id or no usable option (then
/// it's a notice, not a question).
public struct PermissionRequest: Sendable, Hashable {
  public var requestID: String
  public var summary: String?
  public var toolName: String?
  public var toolID: String?
  public var options: [PermissionOption]

  public init?(block: Block) {
    guard block.kind == .permissionRequest,
      let requestID = block.requestID,
      let options = block.options,
      options.contains(where: { $0.optionID != nil })
    else { return nil }
    self.requestID = requestID
    self.summary = block.summary ?? block.body
    self.toolName = block.name
    self.toolID = block.toolID
    self.options = options
  }
}

struct AnyCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
