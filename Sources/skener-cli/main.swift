import Foundation
import PrinterKit

// Command-line tool for testing a printer/scanner without the app.
// Run `skener-cli` without arguments for usage.

let usage = """
  usage: skener-cli <command> <host> [options]

  printer
    info       <host>                    model, state, supplies, trays, print options
    jobs       <host>                    active and recent print jobs
    identify   <host>                    make the printer beep / flash
    print      <host> <file.pdf> [--copies N] [--duplex] [--mono] [--pages 1-3] [--media iso_a5_148x210mm]
    cancel     <host> <job-id>

  scanner
    caps       <host>                    scanner capabilities
    status     <host>                    scanner and feeder state
    scan       <host> [--platen] [--simplex] [--gray] [--dpi 300] [--out dir]

  options
    -v                                   log every HTTP exchange
    --port N                             eSCL port (default 80)
  """

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
  print(usage)
  exit(2)
}

func option(_ name: String) -> String? {
  guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
  return args[index + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

let command = args[0]
var device = DeviceAddress(host: args[1])
device.esclPort = option("--port").flatMap(Int.init)

let log: LogSink? = flag("-v") ? Console.log : nil
let base = URLSessionTransport()
let transport: any HTTPTransport = log.map { LoggingTransport(base, log: $0) } ?? base
let printer = IPPClient(printerURI: device.printerURI, transport: transport)
let scanner = ESCLClient(endpoint: device.scannerEndpoint, transport: transport, log: log)

enum Console {
  @Sendable static func log(_ line: String) { print(line) }
}

func percent(_ level: Int?) -> String { level.map { "\($0) %" } ?? "?" }

do {
  switch command {
  case "info":
    let info = try await printer.printerInfo()
    print("\(info.makeAndModel) — \(info.state), accepting jobs: \(info.isAcceptingJobs)")
    if !info.alerts.isEmpty { print("alerts: \(info.alerts.joined(separator: ", "))") }
    print("supplies:")
    for supply in info.supplies { print("  \(supply.name): \(percent(supply.level))") }
    print("trays:")
    for tray in info.trays {
      print(
        "  \(tray.name): \(tray.media.flatMap(MediaSize.init(keyword:))?.displayName ?? "?") level \(percent(tray.level))"
      )
    }
    let caps = info.capabilities
    print("formats: \(caps.documentFormats.joined(separator: ", "))")
    print("sides: \(caps.sides.map(\.rawValue)), color: \(caps.colorModes.map(\.rawValue)), quality: \(caps.qualities)")
    print("media: \(caps.media.prefix(12).joined(separator: ", "))\(caps.media.count > 12 ? " …" : "")")
    print("sources: \(caps.sources), n-up: \(caps.numberUp), copies: \(caps.copies)")

  case "jobs":
    for job in try await printer.jobs() {
      print("#\(job.id)  \(job.state)  \(job.name)  pages: \(job.pagesCompleted.map(String.init) ?? "-")")
    }

  case "identify":
    try await printer.identify()
    print("ok")

  case "print":
    guard args.count >= 3 else {
      print(usage)
      exit(2)
    }
    let file = URL(fileURLWithPath: args[2])
    var ticket = PrintTicket()
    ticket.copies = option("--copies").flatMap(Int.init) ?? 1
    if flag("--duplex") { ticket.sides = .longEdge }
    if flag("--mono") { ticket.colorMode = .monochrome }
    ticket.media = option("--media")
    if let pages = option("--pages") { ticket.pageRanges = PrintTicket.parsePageRanges(pages) ?? [] }
    let info = try await printer.printerInfo()
    let id = try await printer.print(
      try Data(contentsOf: file), format: "application/pdf", jobName: file.lastPathComponent, ticket: ticket,
      capabilities: info.capabilities)
    print("job \(id) sent")

  case "cancel":
    guard args.count >= 3, let id = Int(args[2]) else {
      print(usage)
      exit(2)
    }
    try await printer.cancelJob(id)
    print("job \(id) cancelled")

  case "caps":
    let caps = try await scanner.capabilities()
    print("\(caps.makeAndModel ?? "?") (eSCL \(caps.version))")
    for (name, input) in [("platen", caps.platen), ("feeder", caps.adfSimplex), ("duplex", caps.adfDuplex)] {
      guard let input else {
        print("\(name): none")
        continue
      }
      print("\(name): \(input.maxWidth)×\(input.maxHeight) dpi \(input.resolutions) \(input.colorModes)")
    }

  case "status":
    let status = try await scanner.status()
    print("state: \(status.state), feeder: \(status.feeder.map { "\($0)" } ?? "-")")
    for job in status.jobs.prefix(5) { print("  \(job.uri): \(job.state)") }

  case "scan":
    let caps = try? await scanner.capabilities()
    let settings = ScanSettings(
      source: flag("--platen") ? .platen : .feeder,
      duplex: !flag("--simplex"),
      colorMode: flag("--gray") ? .grayscale : .color,
      resolution: option("--dpi").flatMap(Int.init) ?? 300)
    let folder = URL(fileURLWithPath: option("--out") ?? "scans", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var count = 0
    for try await page in scanner.scan(settings, capabilities: caps) {
      count += 1
      let file = folder.appendingPathComponent(String(format: "page-%03d.jpg", count))
      try page.write(to: file)
      print("page \(count): \(page.count / 1024) kB → \(file.path)")
    }
    print("done, \(count) pages")

  default:
    print(usage)
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
