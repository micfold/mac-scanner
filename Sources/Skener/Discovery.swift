import Foundation
import Network
import Observation

/// Hledá skenery v síti přes Bonjour (služba _uscan._tcp = eSCL / AirScan).
@Observable @MainActor
final class ScannerDiscovery {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let host: String
        let port: Int
        let rootPath: String
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_uscan._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                for r in results { self?.resolve(r) }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        guard !found.contains(where: { $0.name == name }) else { return }
        let root: String
        if case let .bonjour(txt) = result.metadata, let rs = txt["rs"] { root = rs } else { root = "eSCL" }

        // Adresu zjistíme krátkým TCP spojením na službu (preferujeme IPv4).
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: result.endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    let f = Found(name: name, host: h, port: Int(port.rawValue), rootPath: root)
                    Task { @MainActor [weak self] in self?.add(f) }
                }
                conn.cancel()
            case .failed, .waiting:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func add(_ f: Found) {
        guard !found.contains(where: { $0.name == f.name }) else { return }
        found.append(f)
    }
}
