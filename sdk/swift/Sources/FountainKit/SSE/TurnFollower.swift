import Foundation

/// What a turn produces, distilled: streamable pieces plus the final state.
public enum TurnEvent: Sendable {
  /// The conversation the turn belongs to, before it starts — `Run` emits
  /// this first so a caller can link or title the transcript immediately.
  /// `TurnFollower` never emits it; it follows a turn, not a conversation.
  case conversation(Conversation, url: URL)
  case turnStart(turnNumber: Int, turnID: String?)
  /// A chunk of the answer, with paragraph breaks already applied.
  case text(String)
  case thinking(String)
  case tool(name: String, block: Block)
  case permission(PermissionRequest, block: Block)
  /// Every block, before interpretation — for transcript views.
  case block(Block, event: LogEvent)
  case turnEnd(state: TurnState, exitCode: Int?, reason: String?)
}

/// How a followed turn ended. `timeout` is client-side only.
public struct TurnState: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let done: Self = "done"
  public static let failed: Self = "failed"
  public static let interrupted: Self = "interrupted"
  public static let timeout: Self = "timeout"
}

/// Folds a multi-turn, multi-stream log feed into one turn's answer.
/// Port of the TypeScript SDK's `TurnFollower` — the semantics (turn
/// matching, paragraph joining, which block kinds count as the answer)
/// are deliberately identical.
public struct TurnFollower: Sendable {
  public let turnNumber: Int
  public private(set) var turnID: String?
  public private(set) var started = false
  public private(set) var state: TurnState?
  public private(set) var exitCode: Int?
  public private(set) var reason: String?
  public private(set) var tools: [String] = []

  private var chunks: [String] = []
  private var breakBeforeText = false

  public init(turnNumber: Int) {
    self.turnNumber = turnNumber
  }

  /// The accumulated answer so far.
  public var text: String {
    chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var finished: Bool { state != nil }

  public mutating func apply(_ event: LogEvent) -> [TurnEvent] {
    switch event.kind {
    case .stage: applyStage(event)
    case .output: applyOutput(event)
    default: []
    }
  }

  private mutating func applyStage(_ event: LogEvent) -> [TurnEvent] {
    guard event.stage == "turn", let meta = event.stageData else { return [] }
    let metaTurnID = meta["turn_id"]?.stringValue
    let metaTurnNumber: Int? =
      if case .number(let n) = meta["turn_number"] { Int(n) } else { nil }

    // Match on turn id when we know it, else on turn number.
    let matches =
      if let turnID, let metaTurnID { metaTurnID == turnID } else { metaTurnNumber == turnNumber }
    guard matches else { return [] }

    switch event.state {
    case .started:
      started = true
      if turnID == nil { turnID = metaTurnID }
      return [.turnStart(turnNumber: turnNumber, turnID: turnID)]
    case .done, .failed, .interrupted:
      let ended = TurnState(rawValue: event.state!.rawValue)
      state = ended
      if case .number(let code) = meta["exit_code"] { exitCode = Int(code) }
      reason = meta["reason"]?.stringValue ?? meta["stop_reason"]?.stringValue
      return [.turnEnd(state: ended, exitCode: exitCode, reason: reason)]
    default:
      return []
    }
  }

  private mutating func applyOutput(_ event: LogEvent) -> [TurnEvent] {
    // Someone else's turn (or history replay of an older one).
    if let eventTurn = event.turnID, let turnID, eventTurn != turnID { return [] }
    // Tail of an older turn arriving before ours starts.
    if !started && turnID == nil { return [] }

    let acp = event.stream == .acp
    var events: [TurnEvent] = []
    for block in event.blocks ?? [] {
      events.append(.block(block, event: event))
      events.append(contentsOf: apply(block: block, acp: acp))
    }
    return events
  }

  private mutating func apply(block: Block, acp: Bool) -> [TurnEvent] {
    switch block.kind {
    case .text:
      guard let body = block.body, !body.isEmpty else { return [] }
      let prefix = paragraphBreak(acp: acp)
      chunks.append(prefix + body)
      breakBeforeText = false
      return [.text(prefix + body)]
    case .thinking:
      guard let body = block.body else { return [] }
      return [.thinking(body)]
    case .raw, .initialize:
      // Transport bookkeeping; not even a paragraph break.
      return []
    case .permissionRequest:
      breakBeforeText = true
      guard let request = PermissionRequest(block: block) else { return [] }
      return [.permission(request, block: block)]
    case .toolUse:
      breakBeforeText = true
      guard let name = block.name else { return [] }
      if !tools.contains(name) { tools.append(name) }
      return [.tool(name: name, block: block)]
    case .result:
      breakBeforeText = true
      // Counts as the answer only when nothing else did.
      guard chunks.isEmpty, let body = block.body, !body.isEmpty else { return [] }
      chunks.append(body)
      return [.text(body)]
    case .error:
      breakBeforeText = true
      guard let body = block.body else { return [] }
      let line = "\n[error] \(body)\n"
      chunks.append(line)
      return [.text(line)]
    default:
      breakBeforeText = true
      return []
    }
  }

  /// ACP chunks are pieces of one message and join with nothing; legacy
  /// stdout rows are whole messages and join as paragraphs; text after a
  /// tool call always starts a new paragraph.
  private func paragraphBreak(acp: Bool) -> String {
    guard let last = chunks.last else { return "" }
    if acp && !breakBeforeText { return "" }
    return last.hasSuffix("\n") ? "" : "\n\n"
  }
}
