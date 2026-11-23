import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A minimal HTTP request. Protocol clients build these; transports send them.
public struct HTTPRequest: Sendable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data?
  public var timeout: TimeInterval

  public init(
    method: String,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 30
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }
}

public struct HTTPResponse: Sendable {
  public var status: Int
  /// Header names are lower-cased.
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }

  public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum TransportError: Error, Sendable, Equatable {
  case unreachable(host: String, reason: String)
  case cancelled
}

/// Sends HTTP requests. Injected into the protocol clients so they can be tested
/// against canned responses and decorated (e.g. with logging).
public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Log sink used by ``LoggingTransport`` and the clients. One line per event.
public typealias LogSink = @Sendable (String) -> Void

// MARK: - URLSession

/// Production transport backed by `URLSession`. Cancelling the calling task
/// cancels the underlying request.
public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  public init(requestTimeout: TimeInterval = 120) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = 600
    config.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: config)
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeout
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

    let host = request.url.host ?? request.url.absoluteString
    let session = self.session
    let box = CancellableTaskBox()
    try Task.checkCancellation()

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: urlRequest) { data, response, error in
          if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            continuation.resume(
              throwing: cancelled
                ? TransportError.cancelled
                : TransportError.unreachable(host: host, reason: error.localizedDescription))
            return
          }
          let http = response as? HTTPURLResponse
          var headers: [String: String] = [:]
          for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
          }
          continuation.resume(
            returning: HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data ?? Data()))
        }
        box.set(task)
        task.resume()
      }
    } onCancel: {
      box.cancel()
    }
  }
}

/// Holds a `URLSessionTask` so a cancellation handler on another thread can cancel it.
private final class CancellableTaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var isCancelled = false

  func set(_ task: URLSessionTask) {
    lock.lock()
    self.task = task
    let cancelled = isCancelled
    lock.unlock()
    if cancelled { task.cancel() }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}

// MARK: - Logging decorator

/// Wraps another transport and reports every exchange to a ``LogSink``.
public struct LoggingTransport: HTTPTransport {
  private let base: any HTTPTransport
  private let log: LogSink

  public init(_ base: any HTTPTransport, log: @escaping LogSink) {
    self.base = base
    self.log = log
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let label = "\(request.method) \(request.url.path)"
    let started = Date()
    log("→ \(label)")
    if let body = request.body, Self.isText(request.headers["Content-Type"]),
      let text = String(data: body, encoding: .utf8)
    {
      log(Self.indent(text))
    }
    do {
      let response = try await base.send(request)
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      var line = "← \(response.status) \(label) · \(response.body.count) B · \(ms) ms"
      if let location = response.header("location") { line += " · Location: \(location)" }
      log(line)
      if Self.isText(response.header("content-type")), response.body.count < 4000,
        let text = String(data: response.body, encoding: .utf8), !text.isEmpty
      {
        log(Self.indent(text))
      }
      return response
    } catch {
      log("← \(label) failed: \(error)")
      throw error
    }
  }

  private static func isText(_ contentType: String?) -> Bool {
    guard let contentType = contentType?.lowercased() else { return false }
    return contentType.contains("xml") || contentType.hasPrefix("text/")
  }

  private static func indent(_ text: String) -> String {
    "  " + text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  ")
  }
}
