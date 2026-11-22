import Foundation

// MARK: - Schopnosti skeneru (GET /eSCL/ScannerCapabilities)

public struct InputCaps: Sendable, Equatable {
    /// Rozměry v 1/300 palce (jednotka eSCL).
    public var minWidth: Int
    public var maxWidth: Int
    public var minHeight: Int
    public var maxHeight: Int
    public var colorModes: [String]
    public var documentFormats: [String]
    public var resolutions: [Int]

    public init(minWidth: Int = 16, maxWidth: Int = 2550, minHeight: Int = 16, maxHeight: Int = 3508,
                colorModes: [String] = [], documentFormats: [String] = [], resolutions: [Int] = []) {
        self.minWidth = minWidth; self.maxWidth = maxWidth
        self.minHeight = minHeight; self.maxHeight = maxHeight
        self.colorModes = colorModes; self.documentFormats = documentFormats; self.resolutions = resolutions
    }

    init(_ el: XElement) {
        self.init(
            minWidth: el.int("MinWidth") ?? 16,
            maxWidth: el.int("MaxWidth") ?? 2550,
            minHeight: el.int("MinHeight") ?? 16,
            maxHeight: el.int("MaxHeight") ?? 3508
        )
        colorModes = Self.unique(el.descendants("ColorMode").map(\.value))
        documentFormats = Self.unique((el.descendants("DocumentFormat") + el.descendants("DocumentFormatExt")).map(\.value))

        var res: [Int] = []
        for d in el.descendants("DiscreteResolution") {
            if let x = d.int("XResolution"), let y = d.int("YResolution"), x == y { res.append(x) }
        }
        // Někdy skener posílá rozsah místo výčtu – vybereme z něj běžné hodnoty.
        for r in el.descendants("ResolutionRange") {
            if let xr = r.child("XResolutionRange"),
               let lo = xr.int("Min"), let hi = xr.int("Max") {
                res.append(contentsOf: [75, 100, 150, 200, 300, 400, 600].filter { $0 >= lo && $0 <= hi })
            }
        }
        resolutions = Self.unique(res).sorted()
    }

    private static func unique<T: Hashable>(_ xs: [T]) -> [T] {
        var seen = Set<T>(); return xs.filter { seen.insert($0).inserted }
    }
}

public struct ScannerCapabilities: Sendable, Equatable {
    public var version: String
    public var makeAndModel: String?
    public var platen: InputCaps?
    public var adfSimplex: InputCaps?
    public var adfDuplex: InputCaps?

    public var hasFeeder: Bool { adfSimplex != nil || adfDuplex != nil }
    public var hasDuplex: Bool { adfDuplex != nil }

    public func caps(for source: InputSource, duplex: Bool) -> InputCaps? {
        switch source {
        case .platen: return platen
        case .feeder: return duplex ? (adfDuplex ?? adfSimplex) : (adfSimplex ?? adfDuplex)
        }
    }

    public static func parse(_ data: Data) throws -> ScannerCapabilities {
        let root = try XMLTree.parse(data)
        let adf = root.first("Adf")
        var caps = ScannerCapabilities(
            version: root.child("Version")?.value ?? root.first("Version")?.value ?? "2.0",
            makeAndModel: root.first("MakeAndModel")?.value,
            platen: root.first("PlatenInputCaps").map(InputCaps.init),
            adfSimplex: adf?.first("AdfSimplexInputCaps").map(InputCaps.init),
            adfDuplex: adf?.first("AdfDuplexInputCaps").map(InputCaps.init)
        )
        // Někteří výrobci hlásí duplex jen přes <scan:AdfOption>Duplex</scan:AdfOption>.
        if caps.adfDuplex == nil, let adf,
           adf.descendants("AdfOption").contains(where: { $0.value == "Duplex" }) {
            caps.adfDuplex = caps.adfSimplex
        }
        return caps
    }
}

// MARK: - Stav skeneru (GET /eSCL/ScannerStatus)

public struct JobInfo: Sendable, Equatable {
    public var uri: String
    public var uuid: String?
    /// Pending, Processing, Completed, Canceled, Aborted
    public var state: String
    public var imagesCompleted: Int?
    public var imagesToTransfer: Int?

    public var isRunning: Bool {
        state == "Pending" || state == "Processing" || (imagesToTransfer ?? 0) > 0
    }

    /// Patří tato položka k úloze s danou URL? (porovnáváme konec cesty / UUID)
    public func matches(_ job: URL) -> Bool {
        let id = job.lastPathComponent
        return uri.hasSuffix("/" + id) || uri == id || uuid == id
    }
}

public struct ScannerStatus: Sendable, Equatable {
    /// Idle, Processing, Testing, Stopped, Down
    public var state: String
    /// např. ScannerAdfLoaded, ScannerAdfEmpty, ScannerAdfJam, ScannerAdfMispick…
    public var adfState: String?
    public var jobs: [JobInfo] = []

    public func job(_ url: URL) -> JobInfo? { jobs.first { $0.matches(url) } }

    public var isIdle: Bool { state == "Idle" }
    public var adfLoaded: Bool? {
        guard let adfState else { return nil }
        if adfState == "ScannerAdfLoaded" { return true }
        if adfState == "ScannerAdfEmpty" { return false }
        return nil
    }
    public var adfProblem: String? {
        guard let adfState, !["ScannerAdfLoaded", "ScannerAdfEmpty", "ScannerAdfProcessing"].contains(adfState) else { return nil }
        switch adfState {
        case "ScannerAdfJam": return "V podavači se zasekl papír."
        case "ScannerAdfDoorOpen", "ScannerAdfHatchOpen": return "Podavač je otevřený."
        case "ScannerAdfMispick": return "Podavač nenabral papír."
        case "ScannerAdfMultipickDetected": return "Podavač nabral více listů najednou."
        default: return "Podavač hlásí: \(adfState)"
        }
    }

    public static func parse(_ data: Data) throws -> ScannerStatus {
        let root = try XMLTree.parse(data)
        let jobs = root.descendants("JobInfo").map { j in
            JobInfo(uri: j.first("JobUri")?.value ?? "",
                    uuid: j.first("JobUuid")?.value,
                    state: j.first("JobState")?.value ?? "Unknown",
                    imagesCompleted: j.int("ImagesCompleted"),
                    imagesToTransfer: j.int("ImagesToTransfer"))
        }
        return ScannerStatus(state: root.child("State")?.value ?? "Unknown",
                             adfState: root.first("AdfState")?.value,
                             jobs: jobs)
    }
}

// MARK: - Nastavení skenu (POST /eSCL/ScanJobs)

public enum InputSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case feeder = "Feeder"
    case platen = "Platen"
    public var id: String { rawValue }
    public var label: String { self == .feeder ? "Podavač" : "Sklo" }
}

public enum ColorMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case color = "RGB24"
    case gray = "Grayscale8"
    public var id: String { rawValue }
    public var label: String { self == .color ? "Barevně" : "Odstíny šedi" }
}

public enum PaperSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case a4, a5, letter, legal
    public var id: String { rawValue }
    public var label: String {
        switch self { case .a4: "A4"; case .a5: "A5"; case .letter: "Letter"; case .legal: "Legal" }
    }
    /// Rozměr v 1/300 palce.
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
    public var source: InputSource
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    public var paper: PaperSize

    public init(source: InputSource = .feeder, duplex: Bool = true, colorMode: ColorMode = .color,
                resolution: Int = 300, paper: PaperSize = .a4) {
        self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.paper = paper
    }

    public var effectiveDuplex: Bool { source == .feeder && duplex }

    /// Sestaví XML požadavek. Stránky si vždy bereme jako JPEG – PDF skládáme sami
    /// (kvůli detekci prázdných stran, dělení dávky a OCR).
    public func xml(version: String = "2.0", caps: InputCaps? = nil) -> String {
        var (w, h) = paper.size300
        if let caps {
            w = min(max(w, caps.minWidth), caps.maxWidth)
            h = min(max(h, caps.minHeight), caps.maxHeight)
        }
        var res = resolution
        if let caps, !caps.resolutions.isEmpty, !caps.resolutions.contains(res) {
            // nejbližší podporované rozlišení
            res = caps.resolutions.min(by: { abs($0 - res) < abs($1 - res) }) ?? res
        }
        var color = colorMode.rawValue
        if let caps, !caps.colorModes.isEmpty, !caps.colorModes.contains(color) {
            color = caps.colorModes.contains("RGB24") ? "RGB24" : caps.colorModes[0]
        }
        let format = "image/jpeg"
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>\(version)</pwg:Version>
          <pwg:ScanRegions>
            <pwg:ScanRegion>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
              <pwg:XOffset>0</pwg:XOffset>
              <pwg:YOffset>0</pwg:YOffset>
              <pwg:Width>\(w)</pwg:Width>
              <pwg:Height>\(h)</pwg:Height>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:DocumentFormat>\(format)</pwg:DocumentFormat>
          <scan:DocumentFormatExt>\(format)</scan:DocumentFormatExt>
          <pwg:InputSource>\(source.rawValue)</pwg:InputSource>
          <scan:ColorMode>\(color)</scan:ColorMode>
          <scan:XResolution>\(res)</scan:XResolution>
          <scan:YResolution>\(res)</scan:YResolution>

        """
        if source == .feeder {
            x += "  <scan:Duplex>\(duplex ? "true" : "false")</scan:Duplex>\n"
        }
        x += "</scan:ScanSettings>\n"
        return x
    }
}
