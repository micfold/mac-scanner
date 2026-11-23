import Foundation
import PrinterKit

public enum OutputFormat: String, Codable, CaseIterable, Sendable, Identifiable {
  case pdf, jpeg
  public var id: String { rawValue }
  var label: String { self == .pdf ? "PDF" : "JPEG (každá strana zvlášť)" }
  var fileExtension: String { self == .pdf ? "pdf" : "jpg" }
}

/// Everything needed for one kind of scanning job.
public struct ScanPreset: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var scan = ScanSettings()
  public var split = SplitOptions()
  public var ocr = true
  public var output: OutputFormat = .pdf
  public var namePattern = "Sken_{datum}_{č}"
  /// `~` is expanded.
  public var folder = "~/Documents/Skeny"
  /// Share of the page (0.0003–0.01) under which a page counts as blank.
  public var blankThreshold = 0.0015

  public var folderURL: URL {
    URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
  }

  public static var defaults: [ScanPreset] {
    [
      ScanPreset(
        name: "Faktury", scan: ScanSettings(source: .feeder, duplex: true, colorMode: .color),
        split: SplitOptions(mode: .blankSeparator), namePattern: "Faktura_{datum}_{č}",
        folder: "~/Documents/Skeny/Faktury"),
      ScanPreset(
        name: "Smlouvy", scan: ScanSettings(source: .feeder, duplex: true, colorMode: .grayscale),
        split: SplitOptions(mode: .single), namePattern: "Smlouva_{datum}_{č}",
        folder: "~/Documents/Skeny/Smlouvy"),
      ScanPreset(
        name: "Účtenky", scan: ScanSettings(source: .platen, duplex: false),
        split: SplitOptions(mode: .eachPage), namePattern: "Uctenka_{datum}_{č}",
        folder: "~/Documents/Skeny/Uctenky"),
      ScanPreset(
        name: "Fotky", scan: ScanSettings(source: .platen, duplex: false),
        split: SplitOptions(mode: .eachPage, removeBlankPages: false), ocr: false, output: .jpeg,
        namePattern: "Foto_{datum}_{č}", folder: "~/Pictures/Skeny"),
    ]
  }
}
