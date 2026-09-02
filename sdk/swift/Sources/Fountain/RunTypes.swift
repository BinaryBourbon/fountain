import Foundation

public enum TurnState: String, Sendable {
  case done, failed, interrupted, timeout
}

public struct PermissionOption: Equatable, Sendable {
  public let optionID: String
  public let kind: String?
  public let name: String?
  public let raw: JSONObject
}

public struct PermissionRequest: Equatable, Sendable {
  public let requestID: String
  public let summary: String?
  public let toolName: String?
  public let toolID: String?
  public let options: [PermissionOption]
}

public enum RunEvent: Equatable, Sendable {
  case conversation(id: String, conversation: JSONObject, url: URL)
  case turnStart(turnNumber: Int, turnID: String?)
  case text(String)
  case thinking(String)
  case tool(name: String, block: JSONObject)
  case permission(request: PermissionRequest, block: JSONObject)
  case block(block: JSONObject, event: JSONObject)
  case event(JSONObject)
  case turnEnd(state: TurnState, exitCode: Int?, reason: String?)
}

public struct RunResult: Equatable, Sendable {
  public let conversationID: String
  public let url: URL
  public let turnNumber: Int
  public let text: String
  public let toolsUsed: [String]
  public let state: TurnState
  public let exitCode: Int?
  public let reason: String?
  public let status: String?
  public let events: [JSONObject]?
}

final class TurnFollower {
  let turnNumber: Int
  var turnID: String?
  var started = false
  var state: TurnState?
  var exitCode: Int?
  var reason: String?
  private var chunks: [String] = []
  private var tools: [String] = []
  private var breakBeforeText = false

  init(turnNumber: Int, turnID: String? = nil) {
    self.turnNumber = turnNumber
    self.turnID = turnID
  }

  var text: String { chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
  var toolsUsed: [String] { tools }
  var finished: Bool { state != nil }

  func apply(_ event: JSONObject) -> [RunEvent] {
    if event["kind"]?.stringValue == "stage" { return applyStage(event) }
    guard event["kind"]?.stringValue == "output" else { return [] }
    return applyOutput(event)
  }

  private func applyStage(_ event: JSONObject) -> [RunEvent] {
    guard event["stage"]?.stringValue == "turn" else { return [] }
    let meta = metadata(event["data"])
    let eventTurnID = meta["turn_id"]?.stringValue
    let matches =
      (turnID != nil && eventTurnID == turnID) || meta["turn_number"]?.intValue == turnNumber
    guard matches else { return [] }
    if event["state"]?.stringValue == "started" {
      started = true
      turnID = eventTurnID ?? turnID
      return [.turnStart(turnNumber: turnNumber, turnID: turnID)]
    }
    if let rawState = event["state"]?.stringValue, let terminal = TurnState(rawValue: rawState),
      terminal != .timeout
    {
      state = terminal
      turnID = turnID ?? eventTurnID
      exitCode = meta["exit_code"]?.intValue
      reason = meta["reason"]?.stringValue ?? meta["stop_reason"]?.stringValue
      return [.turnEnd(state: terminal, exitCode: exitCode, reason: reason)]
    }
    return []
  }

  private func applyOutput(_ event: JSONObject) -> [RunEvent] {
    let eventTurnID = event["turn_id"]?.stringValue
    if let turnID, let eventTurnID, eventTurnID != turnID { return [] }
    if !started && turnID == nil { return [] }
    let acp = event["stream"]?.stringValue == "acp"
    var output: [RunEvent] = []
    for block in event["blocks"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
      output.append(.block(block: block, event: event))
      output.append(contentsOf: applyBlock(block, acp: acp))
    }
    return output
  }

  private func applyBlock(_ block: JSONObject, acp: Bool) -> [RunEvent] {
    let body = block["body"]?.stringValue ?? ""
    switch block["kind"]?.stringValue {
    case "text":
      guard !body.isEmpty else { return [] }
      let prefix = paragraphBreak(acp: acp)
      chunks.append(prefix + body)
      breakBeforeText = false
      return [.text(prefix + body)]
    case "thinking": return body.isEmpty ? [] : [.thinking(body)]
    case "raw", "init": return []
    case "permission_request":
      breakBeforeText = true
      guard let request = permissionRequest(block) else { return [] }
      return [.permission(request: request, block: block)]
    case "tool_use":
      breakBeforeText = true
      guard let name = block["name"]?.stringValue else { return [] }
      if !tools.contains(name) { tools.append(name) }
      return [.tool(name: name, block: block)]
    case "result":
      breakBeforeText = true
      guard chunks.isEmpty, !body.isEmpty else { return [] }
      chunks.append(body)
      return [.text(body)]
    case "error":
      breakBeforeText = true
      guard !body.isEmpty else { return [] }
      let value = "\n[error] \(body)\n"
      chunks.append(value)
      return [.text(value)]
    default:
      breakBeforeText = true
      return []
    }
  }

  private func paragraphBreak(acp: Bool) -> String {
    guard !chunks.isEmpty else { return "" }
    if acp && !breakBeforeText { return "" }
    return chunks.last?.hasSuffix("\n") == true ? "" : "\n\n"
  }
}

private func permissionRequest(_ block: JSONObject) -> PermissionRequest? {
  guard let requestID = block["request_id"]?.stringValue else { return nil }
  let options = (block["options"]?.arrayValue ?? []).compactMap { value -> PermissionOption? in
    guard let raw = value.objectValue,
      let id = raw["optionId"]?.stringValue ?? raw["option_id"]?.stringValue
    else { return nil }
    return PermissionOption(
      optionID: id, kind: raw["kind"]?.stringValue, name: raw["name"]?.stringValue, raw: raw)
  }
  guard !options.isEmpty else { return nil }
  return PermissionRequest(
    requestID: requestID,
    summary: block["summary"]?.stringValue ?? block["body"]?.stringValue,
    toolName: block["name"]?.stringValue,
    toolID: block["tool_id"]?.stringValue,
    options: options
  )
}

private func metadata(_ value: JSONValue?) -> JSONObject {
  if let object = value?.objectValue { return object }
  guard let text = value?.stringValue, let data = text.data(using: .utf8) else { return [:] }
  return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
}
