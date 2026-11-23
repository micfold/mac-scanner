import Foundation

public enum ESCLError: Error, Sendable, Equatable {
  case http(status: Int, operation: String)
  case feederEmpty
  case feederProblem(FeederState)
  case busy
  case noJobLocation
  case noFeeder
  case jpegUnsupported
  case jobEnded(state: String)
}

/// Where the scanner's eSCL service lives, typically `http://<host>/eSCL`.
public struct ESCLEndpoint: Sendable, Hashable, Codable {
  public var host: String
  public var port: Int?
  public var rootPath: String
  public var secure: Bool

  public init(host: String, port: Int? = nil, rootPath: String = "eSCL", secure: Bool = false) {
    self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.port = port
    self.rootPath = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    self.secure = secure
  }

  public var baseURL: URL {
    var components = URLComponents()
    components.scheme = secure ? "https" : "http"
    components.host = host
    components.port = port
    components.path = rootPath.isEmpty ? "" : "/" + rootPath
    return components.url ?? URL(string: "http://invalid.local/eSCL")!
  }

  /// A job `Location` may be absolute (sometimes with the printer's own host name) or relative.
  /// Only its path is trusted; it is re-attached to our base URL.
  public func resolve(location: String) -> URL? {
    let path: String
    if let url = URL(string: location), url.scheme != nil {
      path = url.path
    } else {
      path = location.hasPrefix("/") ? location : "/" + location
    }
    guard path.count > 1, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = path
    return components.url
  }
}

/// eSCL (AirScan) client: capabilities, status and scan jobs.
public struct ESCLClient: Sendable {
  public struct Configuration: Sendable {
    /// How many times to retry a `503` (scanner warming up / feeding paper).
    public var busyRetries = 90
    public var retryDelay: Duration = .seconds(1)
    /// How long to keep waiting while the scanner reports our job as still running.
    public var maxJobWait: Duration = .seconds(180)
    /// How long to wait for a first page when the scanner reports no job state at all.
    public var firstPageGrace: Duration = .seconds(30)

    public init() {}
  }

  public let endpoint: ESCLEndpoint
  private let transport: any HTTPTransport
  private let configuration: Configuration
  private let log: LogSink?

  public init(
    endpoint: ESCLEndpoint, transport: any HTTPTransport, configuration: Configuration = .init(),
    log: LogSink? = nil
  ) {
    self.endpoint = endpoint
    self.transport = transport
    self.configuration = configuration
    self.log = log
  }

  // MARK: Queries

  public func capabilities() async throws -> ScannerCapabilities {
    let response = try await get("ScannerCapabilities", timeout: 10)
    guard response.status == 200 else {
      throw ESCLError.http(status: response.status, operation: "ScannerCapabilities")
    }
    return try ScannerCapabilities.parse(response.body)
  }

  public func status() async throws -> ScannerStatus {
    let response = try await get("ScannerStatus", timeout: 10)
    guard response.status == 200 else { throw ESCLError.http(status: response.status, operation: "ScannerStatus") }
    return try ScannerStatus.parse(response.body)
  }

  // MARK: Scanning

  /// Scans and yields each page as JPEG data. Cancelling the consuming task cancels the job.
  public func scan(
    _ settings: ScanSettings, capabilities: ScannerCapabilities?
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await runScan(settings, capabilities: capabilities) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runScan(
    _ settings: ScanSettings, capabilities caps: ScannerCapabilities?, onPage: @Sendable (Data) -> Void
  ) async throws {
    let inputCaps = caps?.caps(for: settings.source, duplex: settings.isDuplex)
    if let caps {
      if settings.source == .feeder && !caps.hasFeeder { throw ESCLError.noFeeder }
      if let formats = inputCaps?.documentFormats, !formats.isEmpty, !formats.contains("image/jpeg") {
        throw ESCLError.jpegUnsupported
      }
    }
    if settings.source == .feeder, let feeder = try? await status().feeder {
      if feeder.isProblem { throw ESCLError.feederProblem(feeder) }
      if feeder == .empty { throw ESCLError.feederEmpty }
    }

    let job = try await createJob(settings.xml(version: caps?.version ?? "2.0", caps: inputCaps))
    var received = 0
    do {
      while let page = try await nextDocument(job: job, received: received) {
        onPage(page)
        received += 1
        if settings.source == .platen { break }  // the flatbed yields exactly one page
      }
      if received == 0 { await cancel(job: job) }  // don't leave the printer stuck in "Scanning…"
    } catch {
      // The current task may be cancelled; send DELETE from an independent task.
      Task.detached { [self] in await cancel(job: job) }
      throw error is CancellationError ? TransportError.cancelled : error
    }
  }

  public func createJob(_ settingsXML: String) async throws -> URL {
    let request = HTTPRequest(
      method: "POST", url: url("ScanJobs"), headers: ["Content-Type": "text/xml"],
      body: Data(settingsXML.utf8), timeout: 30)
    for attempt in 1...10 {
      let response = try await transport.send(request)
      switch response.status {
      case 200, 201:
        guard let location = response.header("location"), let job = endpoint.resolve(location: location) else {
          throw ESCLError.noJobLocation
        }
        return job
      case 409:
        throw ESCLError.feederEmpty
      case 503 where attempt < 10:
        try await Task.sleep(for: .seconds(2))
      case 503:
        throw ESCLError.busy
      default:
        throw ESCLError.http(status: response.status, operation: "ScanJobs")
      }
    }
    throw ESCLError.busy
  }

  /// The next page of a job, or `nil` when there are no more.
  ///
  /// A `404` does not always mean "done": some scanners (Canon among them) answer 404 until
  /// the first page has been captured. On 404 we ask the scanner whether our job is still
  /// running and keep waiting while it is.
  public func nextDocument(job: URL, received: Int = 0) async throws -> Data? {
    let request = HTTPRequest(method: "GET", url: job.appendingPathComponent("NextDocument"), timeout: 120)
    let clock = ContinuousClock()
    let started = clock.now
    var busyCount = 0

    while true {
      try Task.checkCancellation()
      let response = try await transport.send(request)
      switch response.status {
      case 200:
        return response.body
      case 410:
        return nil
      case 404:
        let waited = clock.now - started
        if let info = try? await status().job(job) {
          log?(
            "  job state: \(info.state), completed \(info.imagesCompleted ?? -1), to transfer \(info.imagesToTransfer ?? -1)"
          )
          if info.isRunning && waited < configuration.maxJobWait {
            try await Task.sleep(for: configuration.retryDelay)
            continue
          }
          if !info.isRunning, info.state != "Completed", received == 0 {
            throw ESCLError.jobEnded(state: info.state)
          }
          return nil
        }
        if received == 0 && waited < configuration.firstPageGrace {
          try await Task.sleep(for: configuration.retryDelay)
          continue
        }
        return nil
      case 503:
        busyCount += 1
        if busyCount > configuration.busyRetries { throw ESCLError.busy }
        try await Task.sleep(for: configuration.retryDelay)
      case 409:
        throw ESCLError.feederEmpty
      default:
        throw ESCLError.http(status: response.status, operation: "NextDocument")
      }
    }
  }

  public func cancel(job: URL) async {
    _ = try? await transport.send(HTTPRequest(method: "DELETE", url: job, timeout: 5))
  }

  // MARK: Helpers

  private func url(_ path: String) -> URL { endpoint.baseURL.appendingPathComponent(path) }

  private func get(_ path: String, timeout: TimeInterval) async throws -> HTTPResponse {
    try await transport.send(HTTPRequest(method: "GET", url: url(path), timeout: timeout))
  }
}
