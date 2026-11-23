import AppKit
import Foundation
import PrinterKit

/// Canned device used by SwiftUI previews, the screenshot renderer and tests.
public enum SampleDevice {
  public static let address = DeviceAddress(host: "192.168.1.50")

  public static let printerInfo = PrinterInfo(
    name: "Canon MF750C II Series",
    makeAndModel: "Canon MF750C II Series",
    location: "Pracovna",
    firmware: "03.04",
    uuid: "urn:uuid:00000000-0000-1000-8000-000000000000",
    webPage: URL(string: "http://192.168.1.50/"),
    state: .idle,
    stateReasons: ["none"],
    supplies: [
      Supply(id: 0, name: "Cyan", color: "#00A3DA", type: "toner", level: 80),
      Supply(id: 1, name: "Magenta", color: "#D1007A", type: "toner", level: 80),
      Supply(id: 2, name: "Yellow", color: "#F2C200", type: "toner", level: 12, lowLevel: 15),
      Supply(id: 3, name: "Black", color: "#1D1D1F", type: "toner", level: 90),
    ],
    trays: [
      Tray(
        name: "Tray 1", source: "tray-1", media: "iso_a4_210x297mm", mediaType: "stationery", level: 80, capacity: 250),
      Tray(
        name: "Multi-purpose Tray", source: "by-pass-tray", media: "iso_dl_110x220mm", mediaType: "envelope", level: 0),
    ],
    capabilities: {
      var caps = PrintCapabilities()
      caps.documentFormats = ["application/pdf", "image/jpeg", "image/urf"]
      caps.copies = 1...999
      caps.sides = [.oneSided, .longEdge, .shortEdge]
      caps.colorModes = [.auto, .color, .monochrome]
      caps.qualities = [.normal, .high]
      caps.media = [
        "iso_a4_210x297mm", "iso_a5_148x210mm", "na_letter_8.5x11in", "na_legal_8.5x14in", "iso_dl_110x220mm",
      ]
      caps.mediaDefault = "iso_a4_210x297mm"
      caps.sources = ["auto", "tray-1", "by-pass-tray"]
      caps.numberUp = [1, 2, 4, 6, 9, 16]
      caps.orientations = [.portrait, .landscape]
      caps.scaling = [.auto, .fit, .fill, .none]
      caps.pageRanges = true
      return caps
    }())

  public static let scannerCapabilities: ScannerCapabilities = {
    let input = InputCaps(
      maxWidth: 2551, maxHeight: 4200, colorModes: ["Grayscale8", "RGB24"],
      documentFormats: ["image/jpeg", "application/pdf"], resolutions: [150, 300])
    return ScannerCapabilities(
      version: "2.9", makeAndModel: "MF750C II Series", platen: input, adfSimplex: input, adfDuplex: input)
  }()

  public static let jobs: [PrintJob] = [
    PrintJob(id: 214, name: "Faktura_listopad.pdf", owner: "michael", state: .processing, pagesCompleted: 2),
    PrintJob(id: 215, name: "Objednavka_0412.pdf", owner: "michael", state: .pending),
    PrintJob(id: 213, name: "Smlouva_najem.pdf", owner: "michael", state: .completed, pagesCompleted: 6),
    PrintJob(id: 212, name: "Fotka_rodina.jpg", owner: "michael", state: .completed, pagesCompleted: 1),
  ]

  public static let factory = ServiceFactory { _, _, _ in
    DeviceServices(printer: PreviewPrinter(), scanner: PreviewScanner())
  }

  /// A synthetic scanned page: white sheet with a heading and text lines.
  public static func pageJPEG(seed: Int, blank: Bool = false) -> Data {
    let width = 1240, height = 1754  // A4 at 150 dpi
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if !blank {
      context.setFillColor(CGColor(red: 0.12, green: 0.31, blue: 0.47, alpha: 1))
      context.fill(CGRect(x: 120, y: height - 220, width: 420 + (seed % 3) * 60, height: 46))
      context.setFillColor(CGColor(gray: 0.55, alpha: 1))
      for line in 0..<(18 + seed % 7) {
        let lineWidth = [960, 900, 1000, 760, 980, 640][(line + seed) % 6]
        context.fill(CGRect(x: 120, y: height - 340 - line * 56, width: lineWidth, height: 14))
      }
    }
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
  }
}

struct PreviewPrinter: PrinterService {
  func info() async throws -> PrinterInfo { SampleDevice.printerInfo }
  func jobs() async throws -> [PrintJob] { SampleDevice.jobs }
  func print(
    _ pdf: Data, jobName: String, ticket: PrintTicket, capabilities: PrintCapabilities?
  ) async throws
    -> String
  { "#216" }
  func cancel(job: Int) async throws {}
  func identify() async throws {}
}

struct PreviewScanner: ScannerService {
  func capabilities() async throws -> ScannerCapabilities { SampleDevice.scannerCapabilities }
  func status() async throws -> ScannerStatus { ScannerStatus(state: "Idle", feeder: .loaded) }
  func scan(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for index in 0..<(settings.source == .platen ? 1 : 6) {
        continuation.yield(SampleDevice.pageJPEG(seed: index, blank: index == 3))
      }
      continuation.finish()
    }
  }
}
