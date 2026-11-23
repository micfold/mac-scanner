import Foundation
@preconcurrency import Network
import Observation
import PrinterKit

/// Finds printers/scanners on the local network via Bonjour (`_ipp._tcp`, `_uscan._tcp`).
@MainActor
@Observable
public final class Discovery {
  public struct Device: Identifiable, Hashable, Sendable {
    public var id: String { address.host }
    public var name: String
    public var address: DeviceAddress
  }

  public private(set) var devices: [Device] = []
  @ObservationIgnored private var browsers: [NWBrowser] = []

  public init() {}

  public func start() {
    guard browsers.isEmpty else { return }
    for type in ["_ipp._tcp", "_uscan._tcp"] {
      let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        for result in results { self?.resolve(result, type: type) }
      }
      browser.start(queue: .main)
      browsers.append(browser)
    }
  }

  /// Connects briefly to the service to learn its IPv4 address, then records it.
  private nonisolated func resolve(_ result: NWBrowser.Result, type: String) {
    guard case .service(let name, _, _, _) = result.endpoint else { return }
    let path: String? =
      if case .bonjour(let txt) = result.metadata { txt[type == "_ipp._tcp" ? "rp" : "rs"] } else { nil }

    let parameters = NWParameters.tcp
    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
    let connection = NWConnection(to: result.endpoint, using: parameters)
    connection.stateUpdateHandler = { [weak self, connection] state in
      switch state {
      case .ready:
        if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
          let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
          let portNumber = Int(port.rawValue)
          Task { @MainActor [weak self] in
            self?.record(name: name, host: address, type: type, path: path, port: portNumber)
          }
        }
        connection.cancel()
      case .failed, .waiting:
        connection.cancel()
      default:
        break
      }
    }
    connection.start(queue: .main)
  }

  private func record(name: String, host: String, type: String, path: String?, port: Int) {
    var device = devices.first { $0.address.host == host } ?? Device(name: name, address: DeviceAddress(host: host))
    if type == "_ipp._tcp" {
      device.name = name
      if let path { device.address.ippPath = path }
      device.address.ippPort = port
    } else {
      if let path { device.address.esclPath = path }
      device.address.esclPort = port == 80 ? nil : port
    }
    devices.removeAll { $0.address.host == host }
    devices.append(device)
    devices.sort { $0.name < $1.name }
  }
}
