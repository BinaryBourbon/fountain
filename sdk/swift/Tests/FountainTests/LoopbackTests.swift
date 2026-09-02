import Foundation
import Testing

@testable import Fountain

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Glibc)
  private let streamSocketType = Int32(SOCK_STREAM.rawValue)
  private let sendFlags = Int32(MSG_NOSIGNAL)
#else
  private let streamSocketType = SOCK_STREAM
  private let sendFlags: Int32 = 0
#endif

/// A loopback HTTP server that answers one request with an SSE stream.
///
/// Every other transport test installs `MockURLProtocol`, which replaces the
/// transport, so none of them run `URLSession` at all. This one puts a real
/// socket under the SDK: on Linux that is `FoundationNetworking`, where the
/// streaming delegate and the request timeout behave differently from Darwin,
/// and where the Ubuntu CI leg would otherwise prove only that the package
/// compiles.
private final class LoopbackSSEServer: @unchecked Sendable {
  private let listener: Int32
  private let response: String
  private let lock = NSLock()
  private var received = ""
  let port: UInt16

  var request: String {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  init(response: String) throws {
    self.response = response
    // Every socket call below uses a local handle: the closures would otherwise
    // capture `self` before `port` is initialized.
    let handle = socket(AF_INET, streamSocketType, 0)
    guard handle >= 0 else { throw LoopbackError.failed("socket") }
    var reuse: Int32 = 1
    setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(handle, 1) == 0 else {
      close(handle)
      throw LoopbackError.failed("bind")
    }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(handle, $0, &length)
      }
    }
    guard named == 0 else {
      close(handle)
      throw LoopbackError.failed("getsockname")
    }
    listener = handle
    port = UInt16(bigEndian: assigned.sin_port)
  }

  /// Serves exactly one connection, then returns.
  func start() {
    Thread.detachNewThread { [self] in serve() }
  }

  func stop() {
    close(listener)
  }

  private func serve() {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let client = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        accept(listener, $0, &length)
      }
    }
    guard client >= 0 else { return }
    defer { close(client) }
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var head = Data()
    var buffer = [UInt8](repeating: 0, count: 2048)
    while head.range(of: Data("\r\n\r\n".utf8)) == nil {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      head.append(contentsOf: buffer[0..<count])
    }
    lock.lock()
    received = String(decoding: head, as: UTF8.self)
    lock.unlock()
    let bytes = Array(response.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { pointer -> Int in
        send(client, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, sendFlags)
      }
      guard written > 0 else { return }
      offset += written
    }
  }
}

private enum LoopbackError: Error {
  case failed(String)
}

/// Opt-in, and run in a process of its own.
///
/// FoundationNetworking keeps one global task registry, and it traps at process
/// teardown ("Trying to access a behaviour for a task that in not in the
/// registry") in roughly a fifth of runs when a real `URLSession` shares a
/// process with the mocked ones the rest of the suite installs. That is upstream
/// of this package and reproduces without any SDK code in the path, so the test
/// runs on its own instead: CI gives it a step, and `swift test` for everyone
/// else stays deterministic. Alone it is stable.
///
///     FOUNTAIN_REAL_NETWORK_TESTS=1 swift test \
///       --filter aRealSocketStreamsEventsThroughURLSession
///
/// It belongs to `TransportTests` so that setting the variable and running
/// everything at least serializes it against the mocked tests.
extension TransportTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["FOUNTAIN_REAL_NETWORK_TESTS"] == "1",
      "Set FOUNTAIN_REAL_NETWORK_TESTS=1 to run this in a process of its own"))
  func aRealSocketStreamsEventsThroughURLSession() async throws {
    let server = try LoopbackSSEServer(
      response: """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r
        id: 11
        event: output
        data: {"kind":"output","text":"hello"}

        id: 12
        event: stage
        data: {"stage":"turn","state":"done"}


        """)
    server.start()
    defer { server.stop() }

    // The SSE path builds its own session from this one's configuration, so this
    // session stays unused. FoundationNetworking's task registry crashes at
    // process teardown over a session that was never invalidated, so dispose it.
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let fountain = try Fountain(
      apiKey: "loopback-secret", baseURL: "http://127.0.0.1:\(server.port)", session: session)
    // Read to the end of the stream rather than breaking out of it. Cancelling a
    // live task is what trips FoundationNetworking's task registry on Linux, and
    // the server closes the connection once it has sent both events.
    var ids: [Int] = []
    for try await event in fountain.events(after: 10, wait: false, maxRetries: 0) {
      ids.append(event["id"]?.intValue ?? 0)
    }
    #expect(ids == [11, 12])
    // FoundationNetworking rewrites header names to title case, so compare in
    // one case rather than the case the SDK asked for.
    let request = server.request.lowercased()
    #expect(request.contains("get /api/events/stream"))
    #expect(request.contains("authorization: bearer loopback-secret"))
    #expect(request.contains("last-event-id: 10"))
  }
}
