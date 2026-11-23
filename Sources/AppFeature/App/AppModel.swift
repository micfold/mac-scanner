import Foundation
import Observation
import PrinterKit

public enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case overview, scan, print, jobs, device
  public var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "Přehled"
    case .scan: "Skenování"
    case .print: "Tisk"
    case .jobs: "Fronta úloh"
    case .device: "Tiskárna"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .scan: "doc.viewfinder"
    case .print: "printer"
    case .jobs: "list.bullet.rectangle"
    case .device: "gearshape"
    }
  }
}

/// Composition root for the UI: owns the device session and one model per feature.
@MainActor
@Observable
public final class AppModel {
  public var section: AppSection = .overview
  public var showLog = false

  public let session: DeviceSession
  public let scan: ScanModel
  public let print: PrintModel
  public let jobs: JobsModel
  public let discovery: Discovery
  public let log: LogStore

  public init(factory: ServiceFactory, preferences: Preferences, log: LogStore) {
    self.log = log
    session = DeviceSession(factory: factory, preferences: preferences, log: log)
    scan = ScanModel(session: session, preferences: preferences)
    print = PrintModel(session: session, preferences: preferences)
    jobs = JobsModel(session: session)
    discovery = Discovery()
  }

  /// The real app.
  public static func live() -> AppModel {
    AppModel(factory: .live, preferences: Preferences(), log: LogStore())
  }

  /// Sample device and data for previews and screenshots.
  public static func preview() -> AppModel {
    let preferences = Preferences.ephemeral()
    preferences.device = SampleDevice.address
    let model = AppModel(factory: SampleDevice.factory, preferences: preferences, log: LogStore(writeToDisk: false))
    model.scan.loadSample()
    model.print.loadSample()
    return model
  }

  /// Starts discovery and keeps the device state fresh. Call from a `.task` on the root view.
  public func run() async {
    discovery.start()
    await session.monitor()
  }

  /// Uses the first discovered device when none is configured yet.
  public func adoptDiscoveredDeviceIfNeeded() {
    if session.address.isEmpty, let first = discovery.devices.first { session.connect(to: first.address) }
  }
}
