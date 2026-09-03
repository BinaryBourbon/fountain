import Foundation

/// String-backed "enum" that survives values this client doesn't know yet.
/// The API is additive; a new server value must render, not crash. Model
/// constants give exhaustive-feeling switches via `switch status { case .running: ... default: ... }`.
public protocol WireValue: RawRepresentable, Codable, Sendable, Hashable,
  CustomStringConvertible, ExpressibleByStringLiteral
where RawValue == String {
  init(rawValue: String)
}

extension WireValue {
  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public var description: String { rawValue }
}

public struct ConversationStatus: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let pending: Self = "pending"
  public static let running: Self = "running"
  public static let idle: Self = "idle"
  public static let failed: Self = "failed"
  public static let terminated: Self = "terminated"

  /// No further turn events will ever arrive on these.
  public var isTerminal: Bool { self == .failed || self == .terminated }
}

public struct TurnStatus: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let pending: Self = "pending"
  public static let running: Self = "running"
  public static let completed: Self = "completed"
  public static let failed: Self = "failed"
  public static let interrupted: Self = "interrupted"
}

public struct TurnOrigin: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let user: Self = "user"
  public static let autonomous: Self = "autonomous"
}

public struct SandboxStatus: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let pending: Self = "pending"
  public static let starting: Self = "starting"
  public static let ready: Self = "ready"
  public static let suspended: Self = "suspended"
  public static let terminated: Self = "terminated"
  public static let failed: Self = "failed"
}

public struct SandboxMode: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let ephemeral: Self = "ephemeral"
  public static let persistent: Self = "persistent"
}

public struct SandboxProvider: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let sprites: Self = "sprites"
  public static let e2b: Self = "e2b"
  public static let daytona: Self = "daytona"
  public static let runner: Self = "runner"
}

public struct Runtime: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let claude: Self = "claude"
  public static let codex: Self = "codex"
  public static let gemini: Self = "gemini"
  public static let opencode: Self = "opencode"
}

public struct BlockKind: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let text: Self = "text"
  public static let thinking: Self = "thinking"
  public static let toolUse: Self = "tool_use"
  public static let toolResult: Self = "tool_result"
  public static let initialize: Self = "init"
  public static let result: Self = "result"
  public static let error: Self = "error"
  public static let raw: Self = "raw"
  public static let permissionRequest: Self = "permission_request"
}

public struct EventKind: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let output: Self = "output"
  public static let stage: Self = "stage"
}

public struct EventState: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let started: Self = "started"
  public static let done: Self = "done"
  public static let failed: Self = "failed"
  public static let interrupted: Self = "interrupted"
}

/// Which log streams to read. Joined with commas in the `streams` query param.
public struct LogStream: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let stdout: Self = "stdout"
  public static let stderr: Self = "stderr"
  public static let acp: Self = "acp"
  public static let stage: Self = "stage"
}

public struct ConversationSource: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let ui: Self = "ui"
  public static let api: Self = "api"
  public static let agent: Self = "agent"
}

public struct PresenceState: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let working: Self = "working"
  public static let starting: Self = "starting"
  public static let online: Self = "online"
  public static let asleep: Self = "asleep"
  public static let away: Self = "away"
  public static let machineOffline: Self = "machine_offline"
  public static let failed: Self = "failed"
  public static let offline: Self = "offline"
}

public struct SearchHitKind: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let title: Self = "title"
  public static let prompt: Self = "prompt"
  public static let reply: Self = "reply"
}

public struct NetworkingType: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let unrestricted: Self = "unrestricted"
  public static let limited: Self = "limited"
}

public struct UserRole: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let user: Self = "user"
  public static let admin: Self = "admin"
}
