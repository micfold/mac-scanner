import Foundation
import PrinterKit

/// What the app needs from a printer. Live: IPP (+ CUPS fallback). Preview: canned data.
public protocol PrinterService: Sendable {
  func info() async throws -> PrinterInfo
  func jobs() async throws -> [PrintJob]
  /// Prints a PDF. Returns a human-readable job reference.
  func print(
    _ pdf: Data, jobName: String, ticket: PrintTicket, capabilities: PrintCapabilities?
  ) async throws
    -> String
  func cancel(job: Int) async throws
  func identify() async throws
}

/// What the app needs from a scanner. Live: eSCL. Preview: generated pages.
public protocol ScannerService: Sendable {
  func capabilities() async throws -> ScannerCapabilities
  func status() async throws -> ScannerStatus
  func scan(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> AsyncThrowingStream<Data, any Error>
}

public struct DeviceServices: Sendable {
  public var printer: any PrinterService
  public var scanner: any ScannerService

  public init(printer: any PrinterService, scanner: any ScannerService) {
    self.printer = printer
    self.scanner = scanner
  }
}

/// Builds the services for a device. Swapped for previews, snapshots and tests.
public struct ServiceFactory: Sendable {
  public var make: @Sendable (_ device: DeviceAddress, _ cupsQueue: String?, _ log: LogSink?) -> DeviceServices

  public init(make: @escaping @Sendable (DeviceAddress, String?, LogSink?) -> DeviceServices) {
    self.make = make
  }

  public static let live = ServiceFactory { device, queue, log in
    let base = URLSessionTransport()
    let transport: any HTTPTransport = log.map { LoggingTransport(base, log: $0) } ?? base
    return DeviceServices(
      printer: LivePrinter(client: IPPClient(printerURI: device.printerURI, transport: transport), cupsQueue: queue),
      scanner: ESCLClient(endpoint: device.scannerEndpoint, transport: transport, log: log))
  }
}

extension ESCLClient: ScannerService {}

public enum PrintServiceError: Error, Equatable {
  /// The printer does not accept PDF over IPP and no macOS print queue was chosen.
  case needsSystemQueue
  case systemPrintFailed(String)
}

/// IPP printing; falls back to the macOS print queue (CUPS) when the printer cannot take PDF.
struct LivePrinter: PrinterService {
  let client: IPPClient
  let cupsQueue: String?

  func info() async throws -> PrinterInfo { try await client.printerInfo() }
  func jobs() async throws -> [PrintJob] { try await client.jobs() }
  func cancel(job: Int) async throws { try await client.cancelJob(job) }
  func identify() async throws { try await client.identify() }

  func print(
    _ pdf: Data, jobName: String, ticket: PrintTicket, capabilities: PrintCapabilities?
  ) async throws
    -> String
  {
    if capabilities?.acceptsPDF ?? true {
      let id = try await client.print(
        pdf, format: "application/pdf", jobName: jobName, ticket: ticket, capabilities: capabilities)
      return "#\(id)"
    }
    guard let cupsQueue else { throw PrintServiceError.needsSystemQueue }
    return try await SystemPrintQueue.print(pdf, jobName: jobName, queue: cupsQueue, ticket: ticket)
  }
}

/// The macOS print system (CUPS) via `lp` / `lpstat`.
public enum SystemPrintQueue {
  public static func destinations() async -> [String] {
    guard let output = try? await run("/usr/bin/lpstat", ["-e"]) else { return [] }
    return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
  }

  static func print(_ pdf: Data, jobName: String, queue: String, ticket: PrintTicket) async throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    try pdf.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let output = try await run("/usr/bin/lp", ["-d", queue, "-t", jobName] + ticket.lpOptions + [file.path])
    // "request id is Canon_MF750C-12 (1 file(s))"
    return output.split(separator: " ").dropFirst(3).first.map(String.init) ?? queue
  }

  private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
    try await Task.detached {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintServiceError.systemPrintFailed(output) }
      return output
    }.value
  }
}
