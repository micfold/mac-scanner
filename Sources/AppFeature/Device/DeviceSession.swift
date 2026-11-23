import Foundation
import Observation
import PrinterKit

/// The connected device: its address, services and the latest known state.
/// Shared by every feature; polls the printer and scanner while the app is open.
@MainActor
@Observable
public final class DeviceSession {
  public enum Connection: Equatable {
    case notConfigured
    case connecting
    case online
    case offline(String)
  }

  public private(set) var address: DeviceAddress
  public private(set) var services: DeviceServices
  public var cupsQueue: String? {
    didSet {
      preferences.cupsQueue = cupsQueue
      rebuildServices()
    }
  }

  public private(set) var connection: Connection = .notConfigured
  public private(set) var printer: PrinterInfo?
  public private(set) var scannerCapabilities: ScannerCapabilities?
  public private(set) var scannerStatus: ScannerStatus?

  /// While > 0, polling skips the device (e.g. during a scan job).
  @ObservationIgnored public var busyCount = 0

  private let factory: ServiceFactory
  private let preferences: Preferences
  let log: LogStore

  public init(factory: ServiceFactory, preferences: Preferences, log: LogStore) {
    self.factory = factory
    self.preferences = preferences
    self.log = log
    let address = preferences.device ?? DeviceAddress(host: "")
    self.address = address
    cupsQueue = preferences.cupsQueue
    services = factory.make(address, preferences.cupsQueue, log.sink)
  }

  public var displayName: String {
    printer?.makeAndModel ?? scannerCapabilities?.makeAndModel ?? (address.isEmpty ? "Žádná tiskárna" : address.host)
  }

  public func connect(to address: DeviceAddress) {
    guard address != self.address || connection != .online else { return }
    self.address = address
    preferences.device = address
    printer = nil
    scannerCapabilities = nil
    scannerStatus = nil
    rebuildServices()
    Task { await refresh() }
  }

  private func rebuildServices() {
    services = factory.make(address, cupsQueue, log.sink)
  }

  /// Fetches printer and scanner state. Capabilities are fetched once per connection.
  public func refresh() async {
    guard !address.isEmpty else {
      connection = .notConfigured
      return
    }
    let current = address
    if connection != .online { connection = .connecting }

    let services = self.services
    let knownCaps = scannerCapabilities
    async let printerInfo = Result { try await services.printer.info() }
    async let scannerStatus = Result { try await services.scanner.status() }
    async let scannerCaps = knownCaps == nil ? try? await services.scanner.capabilities() : knownCaps
    let (info, status, caps) = await (printerInfo, scannerStatus, scannerCaps)
    guard current == address else { return }  // the user switched devices meanwhile

    printer = try? info.get()
    self.scannerStatus = try? status.get()
    scannerCapabilities = caps
    switch (info, caps) {
    case (.success, _), (_, .some):
      connection = .online
    case (.failure(let error), nil):
      connection = .offline(ErrorText.describe(error))
    }
  }

  /// Polls every few seconds until the calling task is cancelled.
  public func monitor(every interval: Duration = .seconds(5)) async {
    while !Task.isCancelled {
      if busyCount == 0 { await refresh() }
      try? await Task.sleep(for: interval)
    }
  }
}

extension Result where Failure == any Error {
  init(catching body: () async throws -> Success) async {
    do { self = .success(try await body()) } catch { self = .failure(error) }
  }
}
