import Foundation
import PrinterKit

/// Persisted user choices. A thin typed layer over `UserDefaults`.
@MainActor
public final class Preferences {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// In-memory store for previews, snapshots and tests.
  public static func ephemeral() -> Preferences {
    Preferences(defaults: UserDefaults(suiteName: "skener.ephemeral.\(UUID().uuidString)")!)
  }

  public var device: DeviceAddress? {
    get { value(DeviceAddress.self, "device.v2") }
    set { set(newValue, "device.v2") }
  }

  public var cupsQueue: String? {
    get { defaults.string(forKey: "cupsQueue") }
    set { defaults.set(newValue, forKey: "cupsQueue") }
  }

  public var scanPresets: [ScanPreset]? {
    get { value([ScanPreset].self, "scanPresets.v2") }
    set { set(newValue, "scanPresets.v2") }
  }

  public var printPresets: [PrintPreset]? {
    get { value([PrintPreset].self, "printPresets.v1") }
    set { set(newValue, "printPresets.v1") }
  }

  public var selectedScanPreset: UUID? {
    get { defaults.string(forKey: "selectedScanPreset").flatMap(UUID.init(uuidString:)) }
    set { defaults.set(newValue?.uuidString, forKey: "selectedScanPreset") }
  }

  public var revealAfterSave: Bool {
    get { defaults.object(forKey: "revealAfterSave") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "revealAfterSave") }
  }

  private func value<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
  }

  private func set<T: Encodable>(_ value: T?, _ key: String) {
    defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
  }
}

/// Communication log shown in the app (⌘L) and written to ~/Library/Logs/Skener.log.
@MainActor
@Observable
public final class LogStore {
  public private(set) var lines: [String] = []
  private let file: FileHandle?

  public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Skener.log")

  public init(writeToDisk: Bool = true) {
    guard writeToDisk else {
      file = nil
      return
    }
    let url = Self.fileURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    file = try? FileHandle(forWritingTo: url)
    _ = try? file?.seekToEnd()
  }

  public func append(_ line: String) {
    let stamped = "\(Date.now.formatted(.dateTime.hour().minute().second()))  \(line)"
    lines.append(stamped)
    if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
    file?.write(Data((stamped + "\n").utf8))
  }

  public func clear() { lines.removeAll() }

  /// A thread-safe sink for the protocol clients.
  public nonisolated var sink: LogSink {
    { [weak self] line in Task { @MainActor [weak self] in self?.append(line) } }
  }
}
