import Foundation

// MARK: - Capabilities (GET /eSCL/ScannerCapabilities)

/// What one input source (flatbed, feeder, duplex feeder) supports.
/// Sizes are in 1/300 inch, the eSCL unit.
public struct InputCaps: Sendable, Equatable {
  public var minWidth = 16
  public var maxWidth = 2550
  public var minHeight = 16
  public var maxHeight = 3508
  public var colorModes: [String] = []
  public var documentFormats: [String] = []
  public var resolutions: [Int] = []

  public init(
    minWidth: Int = 16, maxWidth: Int = 2550, minHeight: Int = 16, maxHeight: Int = 3508,
    colorModes: [String] = [], documentFormats: [String] = [], resolutions: [Int] = []
  ) {
    self.minWidth = minWidth
    self.maxWidth = maxWidth
    self.minHeight = minHeight
    self.maxHeight = maxHeight
    self.colorModes = colorModes
    self.documentFormats = documentFormats
    self.resolutions = resolutions
  }

  init(_ element: XElement) {
    minWidth = element.int("MinWidth") ?? 16
    maxWidth = element.int("MaxWidth") ?? 2550
    minHeight = element.int("MinHeight") ?? 16
    maxHeight = element.int("MaxHeight") ?? 3508
    colorModes = element.all("ColorMode").map(\.value).uniqued()
    documentFormats = (element.all("DocumentFormat") + element.all("DocumentFormatExt")).map(\.value).uniqued()

    var resolutions = element.all("DiscreteResolution").compactMap { entry -> Int? in
      guard let x = entry.int("XResolution"), let y = entry.int("YResolution"), x == y else { return nil }
      return x
    }
    // Some scanners describe a range instead of discrete values.
    for range in element.all("XResolutionRange") {
      if let low = range.int("Min"), let high = range.int("Max") {
        resolutions += [75, 100, 150, 200, 300, 400, 600].filter { (low...high).contains($0) }
      }
    }
    self.resolutions = resolutions.uniqued().sorted()
  }

  /// The supported resolution closest to `wanted` (or `wanted` if nothing is advertised).
  public func nearestResolution(to wanted: Int) -> Int {
    resolutions.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
  }
}

public struct ScannerCapabilities: Sendable, Equatable {
  public var version: String
  public var makeAndModel: String?
  public var platen: InputCaps?
  public var adfSimplex: InputCaps?
  public var adfDuplex: InputCaps?

  public init(
    version: String = "2.0", makeAndModel: String? = nil, platen: InputCaps? = nil,
    adfSimplex: InputCaps? = nil, adfDuplex: InputCaps? = nil
  ) {
    self.version = version
    self.makeAndModel = makeAndModel
    self.platen = platen
    self.adfSimplex = adfSimplex
    self.adfDuplex = adfDuplex
  }

  public var hasFeeder: Bool { adfSimplex != nil || adfDuplex != nil }
  public var hasDuplex: Bool { adfDuplex != nil }

  public func caps(for source: ScanSource, duplex: Bool) -> InputCaps? {
    switch source {
    case .platen: platen
    case .feeder: duplex ? (adfDuplex ?? adfSimplex) : (adfSimplex ?? adfDuplex)
    }
  }

  public static func parse(_ data: Data) throws -> ScannerCapabilities {
    let root = try XElement.parse(data)
    let adf = root.first("Adf")
    var caps = ScannerCapabilities(
      version: root.child("Version")?.value ?? "2.0",
      makeAndModel: root.first("MakeAndModel")?.value,
      platen: root.first("PlatenInputCaps").map(InputCaps.init),
      adfSimplex: adf?.first("AdfSimplexInputCaps").map(InputCaps.init),
      adfDuplex: adf?.first("AdfDuplexInputCaps").map(InputCaps.init))
    // Some vendors only announce duplex via <scan:AdfOption>Duplex</scan:AdfOption>.
    if caps.adfDuplex == nil, adf?.all("AdfOption").contains(where: { $0.value == "Duplex" }) == true {
      caps.adfDuplex = caps.adfSimplex
    }
    return caps
  }
}

// MARK: - Status (GET /eSCL/ScannerStatus)

public struct ScanJobInfo: Sendable, Equatable {
  public var uri: String
  public var uuid: String?
  /// Pending, Processing, Completed, Canceled, Aborted
  public var state: String
  public var imagesCompleted: Int?
  public var imagesToTransfer: Int?

  public var isRunning: Bool {
    state == "Pending" || state == "Processing" || (imagesToTransfer ?? 0) > 0
  }

  /// Whether this entry describes the job at `url` (matched on the last path component).
  public func matches(_ url: URL) -> Bool {
    let id = url.lastPathComponent
    return uri.hasSuffix("/" + id) || uri == id || uuid == id
  }
}

public enum FeederState: Sendable, Equatable {
  case loaded, empty, jammed, open, mispick, multipick, other(String)

  init(_ raw: String) {
    switch raw {
    case "ScannerAdfLoaded", "ScannerAdfProcessing": self = .loaded
    case "ScannerAdfEmpty": self = .empty
    case "ScannerAdfJam": self = .jammed
    case "ScannerAdfDoorOpen", "ScannerAdfHatchOpen": self = .open
    case "ScannerAdfMispick": self = .mispick
    case "ScannerAdfMultipickDetected": self = .multipick
    default: self = .other(raw)
    }
  }

  public var isProblem: Bool {
    switch self {
    case .loaded, .empty: false
    default: true
    }
  }
}

public struct ScannerStatus: Sendable, Equatable {
  /// Idle, Processing, Testing, Stopped, Down
  public var state: String
  public var feeder: FeederState?
  public var jobs: [ScanJobInfo] = []

  public init(state: String, feeder: FeederState? = nil, jobs: [ScanJobInfo] = []) {
    self.state = state
    self.feeder = feeder
    self.jobs = jobs
  }

  public var isIdle: Bool { state == "Idle" }
  public func job(_ url: URL) -> ScanJobInfo? { jobs.first { $0.matches(url) } }

  public static func parse(_ data: Data) throws -> ScannerStatus {
    let root = try XElement.parse(data)
    let jobs = root.all("JobInfo").map { job in
      ScanJobInfo(
        uri: job.first("JobUri")?.value ?? "",
        uuid: job.first("JobUuid")?.value,
        state: job.first("JobState")?.value ?? "Unknown",
        imagesCompleted: job.int("ImagesCompleted"),
        imagesToTransfer: job.int("ImagesToTransfer"))
    }
    return ScannerStatus(
      state: root.child("State")?.value ?? "Unknown",
      feeder: root.first("AdfState").map { FeederState($0.value) },
      jobs: jobs)
  }
}

// MARK: - Scan settings (POST /eSCL/ScanJobs)

public enum ScanSource: String, Codable, CaseIterable, Sendable, Identifiable {
  case feeder = "Feeder"
  case platen = "Platen"
  public var id: String { rawValue }
}

public enum ScanColorMode: String, Codable, CaseIterable, Sendable, Identifiable {
  case color = "RGB24"
  case grayscale = "Grayscale8"
  public var id: String { rawValue }
}

public enum PaperSize: String, Codable, CaseIterable, Sendable, Identifiable {
  case a4, a5, letter, legal
  public var id: String { rawValue }

  /// Size in 1/300 inch.
  public var size300: (width: Int, height: Int) {
    switch self {
    case .a4: (2480, 3508)
    case .a5: (1748, 2480)
    case .letter: (2550, 3300)
    case .legal: (2550, 4200)
    }
  }
}

public struct ScanSettings: Codable, Equatable, Sendable {
  public var source: ScanSource
  public var duplex: Bool
  public var colorMode: ScanColorMode
  public var resolution: Int
  public var paper: PaperSize

  public init(
    source: ScanSource = .feeder, duplex: Bool = true, colorMode: ScanColorMode = .color,
    resolution: Int = 300, paper: PaperSize = .a4
  ) {
    self.source = source
    self.duplex = duplex
    self.colorMode = colorMode
    self.resolution = resolution
    self.paper = paper
  }

  public var isDuplex: Bool { source == .feeder && duplex }

  /// The eSCL request body. Pages are always requested as JPEG: the app assembles PDFs
  /// itself so it can drop blank pages, split batches and add an OCR text layer.
  public func xml(version: String = "2.0", caps: InputCaps? = nil) -> String {
    var (width, height) = paper.size300
    var resolution = self.resolution
    var color = colorMode.rawValue
    if let caps {
      width = min(max(width, caps.minWidth), caps.maxWidth)
      height = min(max(height, caps.minHeight), caps.maxHeight)
      resolution = caps.nearestResolution(to: resolution)
      if !caps.colorModes.isEmpty, !caps.colorModes.contains(color) {
        color = caps.colorModes.contains("RGB24") ? "RGB24" : caps.colorModes[0]
      }
    }
    let duplexLine = source == .feeder ? "\n  <scan:Duplex>\(duplex)</scan:Duplex>" : ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
      xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
        <pwg:Version>\(version)</pwg:Version>
        <pwg:ScanRegions>
          <pwg:ScanRegion>
            <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
            <pwg:XOffset>0</pwg:XOffset>
            <pwg:YOffset>0</pwg:YOffset>
            <pwg:Width>\(width)</pwg:Width>
            <pwg:Height>\(height)</pwg:Height>
          </pwg:ScanRegion>
        </pwg:ScanRegions>
        <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
        <pwg:InputSource>\(source.rawValue)</pwg:InputSource>
        <scan:ColorMode>\(color)</scan:ColorMode>
        <scan:XResolution>\(resolution)</scan:XResolution>
        <scan:YResolution>\(resolution)</scan:YResolution>\(duplexLine)
      </scan:ScanSettings>

      """
  }
}

extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
