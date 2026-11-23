import Foundation

// MARK: - Printer state

public enum PrinterState: Int, Sendable, Equatable, Codable {
  case idle = 3
  case processing = 4
  case stopped = 5
  case unknown = 0
}

/// One consumable (toner, drum, waste box …) from the `marker-*` attributes.
public struct Supply: Sendable, Equatable, Identifiable, Codable {
  public var id: Int
  public var name: String
  /// `#RRGGBB`, or `none` / `#RRGGBB#RRGGBB` for multi-colour parts.
  public var color: String?
  public var type: String?
  /// 0–100, or `nil` when the printer does not know.
  public var level: Int?
  public var lowLevel: Int?

  public init(id: Int, name: String, color: String? = nil, type: String? = nil, level: Int? = nil, lowLevel: Int? = nil)
  {
    self.id = id
    self.name = name
    self.color = color
    self.type = type
    self.level = level
    self.lowLevel = lowLevel
  }

  public var isLow: Bool {
    guard let level else { return false }
    return level <= (lowLevel ?? 10)
  }
}

/// A paper source and what is loaded in it.
public struct Tray: Sendable, Equatable, Identifiable, Codable {
  public var id: String { source ?? name }
  public var name: String
  /// IPP `media-source` keyword, e.g. `tray-1`, `by-pass-tray`.
  public var source: String?
  /// PWG media keyword, e.g. `iso_a4_210x297mm`.
  public var media: String?
  public var mediaType: String?
  /// Percentage, `nil` when unknown. `0` means empty.
  public var level: Int?
  public var capacity: Int?

  public init(
    name: String, source: String? = nil, media: String? = nil, mediaType: String? = nil, level: Int? = nil,
    capacity: Int? = nil
  ) {
    self.name = name
    self.source = source
    self.media = media
    self.mediaType = mediaType
    self.level = level
    self.capacity = capacity
  }
}

/// Everything the printer says it can do, used to build the print dialog.
public struct PrintCapabilities: Sendable, Equatable, Codable {
  public var documentFormats: [String] = []
  public var copies: ClosedRange<Int> = 1...1
  public var sides: [Sides] = [.oneSided]
  public var colorModes: [PrintColorMode] = []
  public var qualities: [PrintQuality] = []
  public var media: [String] = []
  public var mediaDefault: String?
  public var sources: [String] = []
  public var numberUp: [Int] = [1]
  public var orientations: [Orientation] = []
  public var scaling: [Scaling] = []
  public var pageRanges = false

  public init() {}

  public var acceptsPDF: Bool { documentFormats.contains("application/pdf") }
}

public struct PrinterInfo: Sendable, Equatable, Codable {
  public var name: String
  public var makeAndModel: String
  public var location: String?
  public var firmware: String?
  public var uuid: String?
  public var webPage: URL?
  public var state: PrinterState
  public var stateReasons: [String]
  public var stateMessage: String?
  public var isAcceptingJobs: Bool
  public var queuedJobs: Int
  public var supplies: [Supply]
  public var trays: [Tray]
  public var capabilities: PrintCapabilities

  public init(
    name: String, makeAndModel: String, location: String? = nil, firmware: String? = nil, uuid: String? = nil,
    webPage: URL? = nil, state: PrinterState = .idle, stateReasons: [String] = [], stateMessage: String? = nil,
    isAcceptingJobs: Bool = true, queuedJobs: Int = 0, supplies: [Supply] = [], trays: [Tray] = [],
    capabilities: PrintCapabilities = .init()
  ) {
    self.name = name
    self.makeAndModel = makeAndModel
    self.location = location
    self.firmware = firmware
    self.uuid = uuid
    self.webPage = webPage
    self.state = state
    self.stateReasons = stateReasons
    self.stateMessage = stateMessage
    self.isAcceptingJobs = isAcceptingJobs
    self.queuedJobs = queuedJobs
    self.supplies = supplies
    self.trays = trays
    self.capabilities = capabilities
  }

  /// State reasons that need attention (everything except `none` and `-report` suffixes).
  public var alerts: [String] {
    stateReasons.filter { $0 != "none" && !$0.hasSuffix("-report") }
  }
}

// MARK: - Jobs

public enum JobState: Int, Sendable, Equatable, Codable {
  case pending = 3, held = 4, processing = 5, stopped = 6, canceled = 7, aborted = 8, completed = 9
  case unknown = 0

  public var isActive: Bool { [.pending, .held, .processing, .stopped].contains(self) }
}

public struct PrintJob: Sendable, Equatable, Identifiable, Codable {
  public var id: Int
  public var name: String
  public var owner: String?
  public var state: JobState
  public var stateReasons: [String]
  public var pagesCompleted: Int?
  public var created: Date?

  public init(
    id: Int, name: String, owner: String? = nil, state: JobState, stateReasons: [String] = [],
    pagesCompleted: Int? = nil, created: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.owner = owner
    self.state = state
    self.stateReasons = stateReasons
    self.pagesCompleted = pagesCompleted
    self.created = created
  }
}

// MARK: - Print ticket

public enum Sides: String, Sendable, Codable, CaseIterable, Identifiable {
  case oneSided = "one-sided"
  case longEdge = "two-sided-long-edge"
  case shortEdge = "two-sided-short-edge"
  public var id: String { rawValue }
}

public enum PrintColorMode: String, Sendable, Codable, CaseIterable, Identifiable {
  case auto, color, monochrome
  public var id: String { rawValue }
}

public enum PrintQuality: Int, Sendable, Codable, CaseIterable, Identifiable {
  case draft = 3, normal = 4, high = 5
  public var id: Int { rawValue }
}

public enum Orientation: Int, Sendable, Codable, CaseIterable, Identifiable {
  case portrait = 3, landscape = 4
  public var id: Int { rawValue }
}

public enum Scaling: String, Sendable, Codable, CaseIterable, Identifiable {
  case auto, fit, fill, none
  public var id: String { rawValue }
}

/// What the user asked for. Converted to IPP job attributes or `lp` options.
public struct PrintTicket: Sendable, Equatable, Codable {
  public var copies = 1
  public var pageRanges: [ClosedRange<Int>] = []
  public var sides: Sides = .oneSided
  public var colorMode: PrintColorMode = .auto
  public var quality: PrintQuality = .normal
  /// PWG media keyword; `nil` = printer default.
  public var media: String?
  /// IPP `media-source`; `nil` = automatic.
  public var mediaSource: String?
  public var numberUp = 1
  /// `nil` = automatic.
  public var orientation: Orientation?
  public var scaling: Scaling = .auto

  public init() {}

  /// Job attributes, leaving out anything the printer does not advertise.
  public func ippJobAttributes(for caps: PrintCapabilities?) -> [IPPAttribute] {
    var attributes: [IPPAttribute] = []
    func supports<T: Equatable>(_ list: [T]?, _ value: T) -> Bool { (list ?? []).isEmpty || list!.contains(value) }

    if copies > 1 { attributes.append(IPPAttribute("copies", .integer(Int32(copies)))) }
    if supports(caps?.sides, sides) { attributes.append(IPPAttribute("sides", .keyword(sides.rawValue))) }
    if colorMode != .auto, supports(caps?.colorModes, colorMode) {
      attributes.append(IPPAttribute("print-color-mode", .keyword(colorMode.rawValue)))
    }
    if supports(caps?.qualities, quality) {
      attributes.append(IPPAttribute("print-quality", .enumeration(Int32(quality.rawValue))))
    }
    if numberUp > 1, supports(caps?.numberUp, numberUp) {
      attributes.append(IPPAttribute("number-up", .integer(Int32(numberUp))))
    }
    if let orientation, supports(caps?.orientations, orientation) {
      attributes.append(IPPAttribute("orientation-requested", .enumeration(Int32(orientation.rawValue))))
    }
    if scaling != .auto, supports(caps?.scaling, scaling) {
      attributes.append(IPPAttribute("print-scaling", .keyword(scaling.rawValue)))
    }
    if !pageRanges.isEmpty, caps?.pageRanges ?? true {
      attributes.append(
        IPPAttribute("page-ranges", pageRanges.map { .range(lower: Int32($0.lowerBound), upper: Int32($0.upperBound)) })
      )
    }
    if let mediaSource {
      // A source can only be requested through media-col, which needs an explicit size.
      var members = [IPPAttribute("media-source", .keyword(mediaSource))]
      if let size = MediaSize(keyword: media ?? caps?.mediaDefault ?? "iso_a4_210x297mm") {
        members.append(
          IPPAttribute(
            "media-size",
            .collection([
              IPPAttribute("x-dimension", .integer(Int32(size.width))),
              IPPAttribute("y-dimension", .integer(Int32(size.height))),
            ])))
      }
      attributes.append(IPPAttribute("media-col", .collection(members)))
    } else if let media {
      attributes.append(IPPAttribute("media", .keyword(media)))
    }
    return attributes
  }

  /// Options for macOS `lp` (CUPS), used when the printer cannot take PDF directly.
  public var lpOptions: [String] {
    var options = ["-n", String(copies), "-o", "sides=\(sides.rawValue)"]
    if colorMode != .auto { options += ["-o", "print-color-mode=\(colorMode.rawValue)"] }
    options += ["-o", "print-quality=\(quality.rawValue)"]
    if let media { options += ["-o", "media=\(media)"] }
    if let mediaSource { options += ["-o", "media-source=\(mediaSource)"] }
    if numberUp > 1 { options += ["-o", "number-up=\(numberUp)"] }
    if let orientation { options += ["-o", "orientation-requested=\(orientation.rawValue)"] }
    if scaling != .auto { options += ["-o", "print-scaling=\(scaling.rawValue)"] }
    if !pageRanges.isEmpty { options += ["-o", "page-ranges=\(Self.format(pageRanges))"] }
    return options
  }

  // MARK: Page ranges

  /// Parses `"1-3, 5, 8-"` style input. Open ends are clamped to `pageCount`.
  public static func parsePageRanges(_ text: String, pageCount: Int = .max) -> [ClosedRange<Int>]? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return [] }
    var ranges: [ClosedRange<Int>] = []
    for part in trimmed.split(separator: ",") {
      let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      switch bounds.count {
      case 1:
        guard let page = Int(bounds[0]), page >= 1 else { return nil }
        ranges.append(page...page)
      case 2:
        guard let low = Int(bounds[0].isEmpty ? "1" : bounds[0]),
          let high = bounds[1].isEmpty ? pageCount : Int(bounds[1]),
          low >= 1, high >= low
        else { return nil }
        ranges.append(low...high)
      default:
        return nil
      }
    }
    return ranges
  }

  public static func format(_ ranges: [ClosedRange<Int>]) -> String {
    ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
      .joined(separator: ",")
  }
}

// MARK: - Media names

/// A PWG self-describing media name such as `iso_a4_210x297mm` or `na_letter_8.5x11in`.
public struct MediaSize: Sendable, Equatable {
  public var keyword: String
  /// Hundredths of a millimetre (the IPP unit).
  public var width: Int
  public var height: Int

  public init?(keyword: String) {
    let parts = keyword.split(separator: "_")
    guard parts.count >= 3, let dims = parts.last else { return nil }
    let isInch = dims.hasSuffix("in")
    let isMM = dims.hasSuffix("mm")
    guard isInch || isMM else { return nil }
    let numbers = dims.dropLast(2).split(separator: "x").compactMap { Double($0) }
    guard numbers.count == 2 else { return nil }
    let factor = isInch ? 2540.0 : 100.0
    self.keyword = keyword
    width = Int((numbers[0] * factor).rounded())
    height = Int((numbers[1] * factor).rounded())
  }

  /// Short human name: `A4`, `Letter`, `DL envelope`, `10×15 cm` …
  public var displayName: String {
    let parts = keyword.split(separator: "_").map(String.init)
    let family = parts[0]
    let name = parts.count > 2 ? parts[1] : ""
    let known: [String: String] = [
      "letter": "Letter", "legal": "Legal", "executive": "Executive", "ledger": "Ledger",
      "number-10": "#10 envelope", "monarch": "Monarch envelope", "index-4x6": "4×6 in",
      "index-5x8": "5×8 in", "invoice": "Statement", "govt-letter": "Government Letter",
      "oficio": "Oficio", "foolscap": "Foolscap",
    ]
    if let friendly = known[name] { return friendly }
    if family == "iso" || family == "jis" || family == "jpn" {
      if name.hasPrefix("dl") { return "DL envelope" }
      if name.hasPrefix("c") && name.count <= 3 { return name.uppercased() + " envelope" }
      if name.first?.isLetter == true && name.dropFirst().allSatisfy(\.isNumber) {
        return name.uppercased() + (family == "jis" ? " (JIS)" : "")
      }
    }
    let w = Double(width) / 1000, h = Double(height) / 1000
    return String(format: "%g×%g cm", (w * 10).rounded() / 10, (h * 10).rounded() / 10)
  }
}
