import Foundation

struct RunPlan: Sendable {
  let start: @Sendable () async throws -> (conversation: JSONObject, turnNumber: Int, after: Int)
}

private struct OpenedRun: Sendable {
  let conversation: JSONObject
  let id: String
  let url: URL
}

/// A turn in flight. Work starts immediately; every observer sees the same run.
public final class Run: @unchecked Sendable {
  private let http: FountainHTTPClient
  private let hub = RunEventHub()
  private let opened = RunPromise<OpenedRun>()
  private let progress = RunProgress()
  private var task: Task<RunResult, Error>!

  init(http: FountainHTTPClient, plan: RunPlan, timeout: TimeInterval?, collectEvents: Bool) {
    self.http = http
    let hub = self.hub
    let opened = self.opened
    let progress = self.progress
    self.task = Task {
      do {
        let planResult = try await plan.start()
        guard let id = planResult.conversation["id"]?.stringValue else {
          throw FountainError(.api, "Conversation response did not include an id")
        }
        let url = http.configuration.conversationURL(id)
        opened.resolve(OpenedRun(conversation: planResult.conversation, id: id, url: url))
        hub.yield(.conversation(id: id, conversation: planResult.conversation, url: url))
        let operation: @Sendable () async throws -> RunResult = {
          try await Self.follow(
            http: http, conversation: planResult.conversation, turnNumber: planResult.turnNumber,
            after: planResult.after, url: url, collectEvents: collectEvents, hub: hub,
            progress: progress
          )
        }
        let result: RunResult
        if let timeout, timeout > 0 {
          result = try await withThrowingTaskGroup(of: RunResult.self) { group in
            group.addTask(operation: operation)
            group.addTask {
              try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
              let snapshot = await progress.snapshot
              throw FountainError(
                .timeout,
                "Timed out after \(timeout)s waiting for turn \(planResult.turnNumber). The turn is still running — resume conversation \(id).",
                conversationID: id, partialText: snapshot.text
              )
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
          }
        } else {
          result = try await operation()
        }
        hub.finish()
        return result
      } catch {
        opened.reject(error)
        hub.finish(throwing: error)
        throw error
      }
    }
  }

  /// A new replaying subscription on each access. Subscribers do not steal events from one another.
  public var events: AsyncThrowingStream<RunEvent, Error> { hub.subscribe() }
  public var textStream: AsyncThrowingStream<String, Error> {
    let source = events
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in source {
            if case .text(let text) = event { continuation.yield(text) }
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func value() async throws -> RunResult { try await task.value }
  public func cancel() { task.cancel() }
  /// Resolves as soon as the conversation POST succeeds, before the turn completes.
  public func conversationID() async throws -> String { try await opened.value().id }
  public func url() async throws -> URL { try await opened.value().url }
  public func conversation() async throws -> JSONObject { try await opened.value().conversation }
  public func cursor() async -> Int { await progress.snapshot.cursor }

  public func answer(requestID: String, optionID: String) async throws {
    _ = try await http.request(
      "POST", "/api/conversations/\(try await conversationID())/requests/\(requestID.pathEncoded)",
      body: .object(["option_id": .string(optionID)]))
  }
  public func interrupt() async throws {
    _ = try await http.request("POST", "/api/conversations/\(try await conversationID())/interrupt")
  }
  public func terminate() async throws {
    _ = try await http.request("POST", "/api/conversations/\(try await conversationID())/terminate")
  }

  private static func follow(
    http: FountainHTTPClient, conversation: JSONObject, turnNumber: Int, after: Int, url: URL,
    collectEvents: Bool, hub: RunEventHub, progress: RunProgress
  ) async throws -> RunResult {
    guard let id = conversation["id"]?.stringValue else {
      throw FountainError(.api, "Conversation response did not include an id")
    }
    let follower = TurnFollower(turnNumber: turnNumber)
    var collected: [JSONObject] = []
    var failureReason: String?
    await progress.update(cursor: after, text: "")
    for try await event in streamEvents(http: http, conversationID: id, after: after) {
      if collectEvents { collected.append(event) }
      hub.yield(.event(event))
      follower.apply(event).forEach(hub.yield)
      await progress.update(cursor: event["id"]?.intValue ?? 0, text: follower.text)
      if follower.finished { break }
      if mayEndConversation(event) {
        let fresh = try? await http.data("GET", "/api/conversations/\(id)")
        let status = fresh?["status"]?.stringValue ?? conversation["status"]?.stringValue
        if status == "failed" || status == "terminated" {
          failureReason = stageReason(event)
          break
        }
      }
    }
    let fresh = try? await http.data("GET", "/api/conversations/\(id)")
    let status = fresh?["status"]?.stringValue ?? conversation["status"]?.stringValue
    let state = follower.state ?? (failureReason == nil ? .timeout : .failed)
    if !follower.finished {
      hub.yield(.turnEnd(state: state, exitCode: nil, reason: failureReason))
    }
    return RunResult(
      conversationID: id, url: url, turnNumber: turnNumber, text: follower.text,
      toolsUsed: follower.toolsUsed, state: state, exitCode: follower.exitCode,
      reason: follower.reason ?? failureReason, status: status,
      events: collectEvents ? collected : nil
    )
  }
}

private final class RunPromise<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private var waiters: [CheckedContinuation<Value, Error>] = []
  func resolve(_ value: Value) { settle(.success(value)) }
  func reject(_ error: Error) { settle(.failure(error)) }
  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
  private func settle(_ result: Result<Value, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume(with: result) }
  }
}

private final class RunEventHub: @unchecked Sendable {
  private let lock = NSLock()
  private var history: [RunEvent] = []
  private var subscribers: [UUID: AsyncThrowingStream<RunEvent, Error>.Continuation] = [:]
  private var completion: Result<Void, Error>?
  func subscribe() -> AsyncThrowingStream<RunEvent, Error> {
    AsyncThrowingStream { continuation in
      let id = UUID()
      lock.lock()
      let finished = completion
      for event in history { continuation.yield(event) }
      if finished == nil { subscribers[id] = continuation }
      lock.unlock()
      if let finished {
        switch finished {
        case .success: continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
      } else {
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
      }
    }
  }
  func yield(_ event: RunEvent) {
    lock.lock()
    guard completion == nil else {
      lock.unlock()
      return
    }
    history.append(event)
    let targets = Array(subscribers.values)
    lock.unlock()
    for target in targets { target.yield(event) }
  }
  func finish(throwing error: Error? = nil) {
    lock.lock()
    guard completion == nil else {
      lock.unlock()
      return
    }
    completion = error.map(Result.failure) ?? .success(())
    let targets = Array(subscribers.values)
    subscribers.removeAll()
    lock.unlock()
    for target in targets {
      if let error { target.finish(throwing: error) } else { target.finish() }
    }
  }
  private func remove(_ id: UUID) {
    lock.lock()
    subscribers[id] = nil
    lock.unlock()
  }
}

private actor RunProgress {
  struct Snapshot {
    var cursor: Int
    var text: String
  }
  private var value = Snapshot(cursor: 0, text: "")
  var snapshot: Snapshot { value }
  func update(cursor: Int, text: String) {
    value.cursor = max(value.cursor, cursor)
    value.text = text
  }
}

private func mayEndConversation(_ event: JSONObject) -> Bool {
  event["kind"]?.stringValue == "stage" && event["stage"]?.stringValue != "turn"
    && (event["state"]?.stringValue == "failed"
      || ["terminate", "sandbox"].contains(event["stage"]?.stringValue))
}
private func stageReason(_ event: JSONObject) -> String? {
  let stage = event["stage"]?.stringValue ?? "stage"
  let state = event["state"]?.stringValue ?? "unknown"
  let data: JSONObject
  if let object = event["data"]?.objectValue {
    data = object
  } else if let text = event["data"]?.stringValue, let bytes = text.data(using: .utf8) {
    data = (try? JSONDecoder().decode(JSONValue.self, from: bytes))?.objectValue ?? [:]
  } else {
    data = [:]
  }
  let detail = data["message"]?.stringValue ?? data["reason"]?.stringValue
  return detail.map { "\(stage)/\(state): \($0)" } ?? "\(stage)/\(state)"
}

extension String {
  var pathEncoded: String {
    addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
  }
}
