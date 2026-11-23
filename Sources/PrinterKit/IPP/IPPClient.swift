import Foundation

/// IPP operation ids (RFC 8011, PWG 5100.x).
public enum IPPOperation {
  public static let printJob: UInt16 = 0x0002
  public static let validateJob: UInt16 = 0x0004
  public static let cancelJob: UInt16 = 0x0008
  public static let getJobs: UInt16 = 0x000A
  public static let getPrinterAttributes: UInt16 = 0x000B
  public static let identifyPrinter: UInt16 = 0x003C
}

/// IPP client for one printer: status, supplies, capabilities, jobs and printing.
public struct IPPClient: Sendable {
  /// e.g. `ipp://192.168.1.50:631/ipp/print`
  public let printerURI: URL
  public var userName: String
  private let transport: any HTTPTransport

  public init(printerURI: URL, transport: any HTTPTransport, userName: String = "skener") {
    self.printerURI = printerURI
    self.transport = transport
    self.userName = userName
  }

  /// `ipp://host[:631]/ipp/print` for a host name or address.
  public static func defaultURI(host: String, port: Int = 631, path: String = "ipp/print") -> URL {
    var components = URLComponents()
    components.scheme = "ipp"
    components.host = host
    components.port = port
    components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return components.url ?? URL(string: "ipp://invalid.local:631/ipp/print")!
  }

  // MARK: Operations

  public func printerInfo() async throws -> PrinterInfo {
    let response = try await send(
      IPPOperation.getPrinterAttributes,
      extra: [IPPAttribute("requested-attributes", PrinterInfo.requestedAttributes.map(IPPValue.keyword))])
    return PrinterInfo(response.groups(IPPTag.printerAttributes).flatMap(\.attributes))
  }

  /// Active jobs first, then recently finished ones.
  public func jobs(limit: Int = 30) async throws -> [PrintJob] {
    var all: [PrintJob] = []
    for which in ["not-completed", "completed"] {
      let response = try await send(
        IPPOperation.getJobs,
        extra: [
          IPPAttribute("limit", .integer(Int32(limit))),
          IPPAttribute("which-jobs", .keyword(which)),
          IPPAttribute("requested-attributes", PrintJob.requestedAttributes.map(IPPValue.keyword)),
        ])
      all += response.groups(IPPTag.jobAttributes).compactMap { PrintJob($0.attributes) }
    }
    return all
  }

  /// Checks a ticket without printing. Throws ``IPPError/status(code:message:)`` if rejected.
  public func validate(format: String, ticket: PrintTicket, capabilities: PrintCapabilities?) async throws {
    _ = try await send(
      IPPOperation.validateJob,
      extra: [IPPAttribute("document-format", .mimeType(format))],
      job: ticket.ippJobAttributes(for: capabilities))
  }

  /// Sends a document. Returns the job id.
  @discardableResult
  public func print(
    _ document: Data, format: String, jobName: String, ticket: PrintTicket, capabilities: PrintCapabilities?
  ) async throws -> Int {
    let response = try await send(
      IPPOperation.printJob,
      extra: [
        IPPAttribute("job-name", .name(jobName)),
        IPPAttribute("document-format", .mimeType(format)),
      ],
      job: ticket.ippJobAttributes(for: capabilities),
      document: document,
      timeout: 300)
    return response.attribute("job-id", in: IPPTag.jobAttributes)?.ints.first ?? 0
  }

  public func cancelJob(_ id: Int) async throws {
    _ = try await send(IPPOperation.cancelJob, extra: [IPPAttribute("job-id", .integer(Int32(id)))])
  }

  /// Makes the printer beep / flash so you can find it (IPP Everywhere).
  public func identify() async throws {
    _ = try await send(
      IPPOperation.identifyPrinter,
      extra: [IPPAttribute("identify-actions", [.keyword("flash"), .keyword("sound")])])
  }

  // MARK: Transport

  private func send(
    _ operation: UInt16, extra: [IPPAttribute], job: [IPPAttribute] = [], document: Data = Data(),
    timeout: TimeInterval = 15
  ) async throws -> IPPMessage {
    var operationAttributes = [
      IPPAttribute("attributes-charset", .charset("utf-8")),
      IPPAttribute("attributes-natural-language", .language("en")),
      IPPAttribute("printer-uri", .uri(printerURI.absoluteString)),
      IPPAttribute("requesting-user-name", .name(userName)),
    ]
    operationAttributes += extra
    var groups = [IPPAttributeGroup(tag: IPPTag.operationAttributes, attributes: operationAttributes)]
    if !job.isEmpty { groups.append(IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: job)) }
    let request = IPPMessage(
      code: operation, requestID: Int32.random(in: 1...Int32.max), groups: groups, document: document)

    let response = try await transport.send(
      HTTPRequest(
        method: "POST", url: httpURL, headers: ["Content-Type": "application/ipp"], body: request.encoded(),
        timeout: timeout))
    guard response.status == 200 else { throw IPPError.http(status: response.status) }
    let message = try IPPMessage.decode(response.body)
    guard message.isSuccess else {
      throw IPPError.status(
        code: message.code,
        message: message.attribute("status-message", in: IPPTag.operationAttributes)?.strings.first)
    }
    return message
  }

  /// IPP travels over HTTP: `ipp://` → `http://` (port 631), `ipps://` → `https://`.
  var httpURL: URL {
    var components = URLComponents(url: printerURI, resolvingAgainstBaseURL: false) ?? URLComponents()
    let secure = components.scheme == "ipps"
    components.scheme = secure ? "https" : "http"
    if components.port == nil { components.port = secure ? 443 : 631 }
    return components.url ?? printerURI
  }
}

// MARK: - Mapping IPP attributes to models

extension PrinterInfo {
  public static let requestedAttributes = [
    "printer-name", "printer-make-and-model", "printer-location", "printer-info", "printer-more-info",
    "printer-uuid", "printer-firmware-string-version", "printer-state", "printer-state-reasons",
    "printer-state-message", "printer-is-accepting-jobs", "queued-job-count",
    "marker-names", "marker-colors", "marker-levels", "marker-types", "marker-low-levels",
    "printer-input-tray", "media-col-ready", "media-ready",
    "document-format-supported", "copies-supported", "sides-supported", "print-color-mode-supported",
    "print-quality-supported", "media-supported", "media-default", "media-source-supported",
    "number-up-supported", "orientation-requested-supported", "print-scaling-supported",
    "page-ranges-supported",
  ]

  init(_ attributes: [IPPAttribute]) {
    func strings(_ name: String) -> [String] { attributes[name]?.strings ?? [] }
    func ints(_ name: String) -> [Int] { attributes[name]?.ints ?? [] }
    func string(_ name: String) -> String? { strings(name).first.flatMap { $0.isEmpty ? nil : $0 } }

    var caps = PrintCapabilities()
    caps.documentFormats = strings("document-format-supported")
    if case .range(let low, let high)? = attributes["copies-supported"]?.values.first {
      caps.copies = Int(low)...Int(max(low, high))
    }
    caps.sides = strings("sides-supported").compactMap(Sides.init(rawValue:))
    caps.colorModes = strings("print-color-mode-supported").compactMap(PrintColorMode.init(rawValue:))
    caps.qualities = ints("print-quality-supported").compactMap(PrintQuality.init(rawValue:))
    caps.media = strings("media-supported").filter { !$0.hasPrefix("custom_") }
    caps.mediaDefault = string("media-default")
    caps.sources = strings("media-source-supported")
    caps.numberUp = Self.expand(attributes["number-up-supported"]).filter { [1, 2, 4, 6, 9, 16].contains($0) }
    if caps.numberUp.isEmpty { caps.numberUp = [1] }
    caps.orientations = ints("orientation-requested-supported").compactMap(Orientation.init(rawValue:))
    caps.scaling = strings("print-scaling-supported").compactMap(Scaling.init(rawValue:))
    caps.pageRanges = attributes["page-ranges-supported"]?.values.first?.bool ?? false

    let names = strings("marker-names")
    let colors = strings("marker-colors")
    let types = strings("marker-types")
    let levels = ints("marker-levels")
    let lows = ints("marker-low-levels")
    let supplies = names.indices.map { index in
      Supply(
        id: index,
        name: names[index],
        color: colors[safe: index],
        type: types[safe: index],
        level: levels[safe: index].flatMap { $0 >= 0 ? min($0, 100) : nil },
        lowLevel: lows[safe: index])
    }

    self.init(
      name: string("printer-name") ?? string("printer-info") ?? "Printer",
      makeAndModel: string("printer-make-and-model") ?? string("printer-info") ?? "Printer",
      location: string("printer-location"),
      firmware: string("printer-firmware-string-version"),
      uuid: string("printer-uuid"),
      webPage: string("printer-more-info").flatMap(URL.init(string:)),
      state: PrinterState(rawValue: ints("printer-state").first ?? 0) ?? .unknown,
      stateReasons: strings("printer-state-reasons"),
      stateMessage: string("printer-state-message"),
      isAcceptingJobs: attributes["printer-is-accepting-jobs"]?.values.first?.bool ?? true,
      queuedJobs: ints("queued-job-count").first ?? 0,
      supplies: supplies,
      trays: Self.trays(attributes),
      capabilities: caps)
  }

  /// Integers listed directly or as ranges.
  static func expand(_ attribute: IPPAttribute?) -> [Int] {
    (attribute?.values ?? []).flatMap { value -> [Int] in
      switch value {
      case .integer(let number): [Int(number)]
      case .range(let low, let high): Array(Int(low)...Int(min(high, 16)))
      default: []
      }
    }
  }

  /// Combines `printer-input-tray` (levels, names) with `media-col-ready` (what is loaded).
  static func trays(_ attributes: [IPPAttribute]) -> [Tray] {
    var loaded: [String: (media: String?, type: String?)] = [:]
    for value in attributes["media-col-ready"]?.values ?? [] {
      guard let members = value.members, let source = members["media-source"]?.strings.first else { continue }
      var media: String?
      if let size = members["media-size"]?.values.first?.members,
        let width = size["x-dimension"]?.ints.first, let height = size["y-dimension"]?.ints.first
      {
        media = members["media-size-name"]?.strings.first ?? MediaSize.keyword(width: width, height: height)
      }
      loaded[source] = (media, members["media-type"]?.strings.first)
    }

    var trays: [Tray] = []
    for value in attributes["printer-input-tray"]?.values ?? [] {
      guard let text = value.string else { continue }
      let fields = Dictionary(
        text.split(separator: ";").compactMap { pair -> (String, String)? in
          let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
          return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
      let name = fields["name"] ?? "Tray"
      if fields["type"] == "other" && name.lowercased().contains("auto") { continue }
      let source = Self.matchSource(name, in: Array(loaded.keys))
      let rawLevel = Int(fields["level"] ?? "") ?? -2
      let capacity = Int(fields["maxcapacity"] ?? "")
      let level: Int? =
        rawLevel == 0
        ? 0 : (rawLevel > 0 && (capacity ?? 0) > 0 ? min(100, rawLevel * 100 / capacity!) : nil)
      trays.append(
        Tray(
          name: name, source: source, media: source.flatMap { loaded[$0]?.media },
          mediaType: source.flatMap { loaded[$0]?.type }, level: level, capacity: capacity))
    }
    // No tray descriptions: fall back to whatever media-col-ready reported.
    if trays.isEmpty {
      trays = loaded.keys.sorted().map {
        Tray(name: $0, source: $0, media: loaded[$0]?.media, mediaType: loaded[$0]?.type)
      }
    }
    return trays
  }

  /// "Tray 1" ↔ `tray-1`, "Multi-purpose Tray" ↔ `by-pass-tray` / `manual`.
  static func matchSource(_ trayName: String, in sources: [String]) -> String? {
    let normalized = trayName.lowercased().replacingOccurrences(of: " ", with: "-")
    if let exact = sources.first(where: { $0 == normalized }) { return exact }
    if normalized.contains("multi") || normalized.contains("pass") || normalized.contains("manual") {
      return sources.first { $0.contains("by-pass") || $0.contains("manual") || $0.contains("multi") }
    }
    if let digit = normalized.last(where: \.isNumber) {
      return sources.first { $0.hasPrefix("tray") && $0.hasSuffix(String(digit)) }
    }
    return nil
  }
}

extension MediaSize {
  /// Best-effort keyword for a size in hundredths of mm (common sizes only).
  static func keyword(width: Int, height: Int) -> String {
    let common = [
      "iso_a4_210x297mm", "iso_a5_148x210mm", "iso_a6_105x148mm", "iso_a3_297x420mm", "na_letter_8.5x11in",
      "na_legal_8.5x14in", "iso_dl_110x220mm", "na_number-10_4.125x9.5in", "iso_c5_162x229mm",
      "na_index-4x6_4x6in", "jis_b5_182x257mm",
    ]
    for keyword in common {
      if let size = MediaSize(keyword: keyword), abs(size.width - width) < 150, abs(size.height - height) < 150 {
        return keyword
      }
    }
    return "custom_\(width / 100)x\(height / 100)mm_\(width / 100)x\(height / 100)mm"
  }
}

extension PrintJob {
  static let requestedAttributes = [
    "job-id", "job-name", "job-originating-user-name", "job-state", "job-state-reasons",
    "job-impressions-completed", "time-at-creation",
  ]

  init?(_ attributes: [IPPAttribute]) {
    guard let id = attributes["job-id"]?.ints.first else { return nil }
    let created = attributes["time-at-creation"]?.ints.first.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    self.init(
      id: id,
      name: attributes["job-name"]?.strings.first ?? "Job \(id)",
      owner: attributes["job-originating-user-name"]?.strings.first,
      state: JobState(rawValue: attributes["job-state"]?.ints.first ?? 0) ?? .unknown,
      stateReasons: attributes["job-state-reasons"]?.strings ?? [],
      pagesCompleted: attributes["job-impressions-completed"]?.ints.first,
      // Printers often report uptime seconds rather than epoch; ignore implausible values.
      created: created.flatMap { $0.timeIntervalSince1970 > 1_000_000_000 ? $0 : nil })
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
