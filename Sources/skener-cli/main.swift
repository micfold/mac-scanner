import Foundation
import ScanCore

// Terminálový nástroj pro ověření spojení se skenerem.
//
//   swift run skener-cli caps   192.168.1.50
//   swift run skener-cli status 192.168.1.50
//   swift run skener-cli scan   192.168.1.50 [--sklo] [--jednostranne] [--seda] [--dpi 300] [--port 80] [--out ./skeny]
//   Přidejte -v pro výpis celé komunikace se skenerem.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    Použití:
      skener-cli caps   <ip-tiskarny> [--port N]
      skener-cli status <ip-tiskarny> [--port N]
      skener-cli scan   <ip-tiskarny> [--sklo] [--jednostranne] [--seda] [--dpi 300] [--port N] [--out slozka]
      -v  vypsat celou komunikaci se skenerem
    """)
    exit(2)
}

guard args.count >= 2 else { usage() }
let command = args[0]
let host = args[1]

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

let endpoint = ESCLEndpoint(host: host, port: option("--port").flatMap(Int.init))
let client = ESCLClient(endpoint: endpoint)
if flag("-v") { client.log = { print($0) } }

do {
    switch command {
    case "caps":
        let c = try await client.capabilities()
        print("Skener:   \(c.makeAndModel ?? "?") (eSCL \(c.version))")
        for (name, ic) in [("Sklo", c.platen), ("Podavač", c.adfSimplex), ("Podavač oboustranně", c.adfDuplex)] {
            guard let ic else { print("\(name): není"); continue }
            print("\(name): max \(ic.maxWidth)×\(ic.maxHeight) (1/300\"), barvy \(ic.colorModes), dpi \(ic.resolutions), formáty \(ic.documentFormats)")
        }
    case "status":
        let s = try await client.status()
        print("Stav: \(s.state)\(s.adfState.map { ", podavač: \($0)" } ?? "")")
        for j in s.jobs.prefix(5) {
            print("  úloha \(j.uri): \(j.state), hotovo \(j.imagesCompleted ?? 0), k přenosu \(j.imagesToTransfer ?? 0)")
        }
    case "scan":
        let caps = try? await client.capabilities()
        let settings = ScanSettings(source: flag("--sklo") ? .platen : .feeder,
                                    duplex: !flag("--jednostranne"),
                                    colorMode: flag("--seda") ? .gray : .color,
                                    resolution: option("--dpi").flatMap(Int.init) ?? 300)
        let out = URL(fileURLWithPath: option("--out") ?? "skeny", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let n = try await client.scan(settings: settings, capabilities: caps) { data, i in
            let file = out.appendingPathComponent(String(format: "strana-%03d.jpg", i + 1))
            try? data.write(to: file)
            print("  stránka \(i + 1): \(data.count / 1024) kB → \(file.path)")
        }
        print("Hotovo, \(n) stran.")
    default:
        usage()
    }
} catch {
    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("Chyba: \(msg)\n".utf8))
    exit(1)
}
