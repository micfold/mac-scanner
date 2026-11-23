import Foundation

/// A network printer/scanner and where its services live.
public struct DeviceAddress: Sendable, Hashable, Codable {
  public var host: String
  /// IPP path, usually `ipp/print` (Bonjour TXT `rp`).
  public var ippPath: String
  public var ippPort: Int
  /// eSCL root, usually `eSCL` (Bonjour TXT `rs`).
  public var esclPath: String
  public var esclPort: Int?

  public init(
    host: String, ippPath: String = "ipp/print", ippPort: Int = 631, esclPath: String = "eSCL", esclPort: Int? = nil
  ) {
    self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.ippPath = ippPath
    self.ippPort = ippPort
    self.esclPath = esclPath
    self.esclPort = esclPort
  }

  /// Accepts `host` or `host:port` (port applies to eSCL, as typed in the scanner field before).
  public init(parsing text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let colon = trimmed.lastIndex(of: ":"), !trimmed.contains("]"),
      let port = Int(trimmed[trimmed.index(after: colon)...])
    {
      self.init(host: String(trimmed[..<colon]), esclPort: port)
    } else {
      self.init(host: trimmed)
    }
  }

  public var isEmpty: Bool { host.isEmpty }
  public var printerURI: URL { IPPClient.defaultURI(host: host, port: ippPort, path: ippPath) }
  public var scannerEndpoint: ESCLEndpoint { ESCLEndpoint(host: host, port: esclPort, rootPath: esclPath) }
  public var webInterface: URL? { URL(string: "http://\(host)/") }
}
