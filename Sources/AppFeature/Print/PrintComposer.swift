import CoreGraphics
import Foundation
import ImageIO
import PrinterKit
import UniformTypeIdentifiers

public struct PrintPreset: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var symbol: String
  public var ticket: PrintTicket

  public static var defaults: [PrintPreset] {
    [
      PrintPreset(name: "Standardní", symbol: "doc", ticket: PrintTicket()),
      PrintPreset(
        name: "Úsporně", symbol: "leaf",
        ticket: modify {
          $0.colorMode = .monochrome
          $0.sides = .longEdge
          $0.numberUp = 2
        }),
      PrintPreset(name: "Oboustranně", symbol: "doc.on.doc", ticket: modify { $0.sides = .longEdge }),
      PrintPreset(
        name: "Fotky", symbol: "photo",
        ticket: modify {
          $0.colorMode = .color
          $0.quality = .high
          $0.scaling = .fill
        }),
      PrintPreset(
        name: "Obálka DL", symbol: "envelope",
        ticket: modify {
          $0.media = "iso_dl_110x220mm"
          $0.mediaSource = "by-pass-tray"
          $0.orientation = .landscape
        }),
    ]
  }

  private static func modify(_ change: (inout PrintTicket) -> Void) -> PrintTicket {
    var ticket = PrintTicket()
    change(&ticket)
    return ticket
  }
}

/// A file queued for printing, already converted to PDF.
struct PrintDocument: Identifiable, Sendable {
  let id = UUID()
  let url: URL
  let pdf: Data
  let pageCount: Int
  var name: String { url.lastPathComponent }
}

enum PrintComposerError: Error, LocalizedError {
  case unsupported(String)
  case unreadable(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let name): "„\(name)“ nelze vytisknout přímo. Uložte ho nejdřív jako PDF."
    case .unreadable(let name): "Soubor „\(name)“ se nepodařilo načíst."
    }
  }
}

/// Turns input files into print-ready PDF data.
enum PrintComposer {
  static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

  static func document(from url: URL) throws -> PrintDocument {
    let type = UTType(filenameExtension: url.pathExtension.lowercased())
    let data: Data
    if type?.conforms(to: .pdf) == true {
      data = try Data(contentsOf: url)
    } else if type?.conforms(to: .image) == true {
      data = try imagePDF(url)
    } else {
      throw PrintComposerError.unsupported(url.lastPathComponent)
    }
    guard let pages = pdfDocument(data)?.numberOfPages, pages > 0 else {
      throw PrintComposerError.unreadable(url.lastPathComponent)
    }
    return PrintDocument(url: url, pdf: data, pageCount: pages)
  }

  /// One A4 page per image frame, image fitted with a small margin.
  static func imagePDF(_ url: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw PrintComposerError.unreadable(url.lastPathComponent)
    }
    let output = NSMutableData()
    var box = a4
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { throw PrintComposerError.unreadable(url.lastPathComponent) }
    for index in 0..<CGImageSourceGetCount(source) {
      guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
      let landscape = image.width > image.height
      var page = landscape ? CGRect(x: 0, y: 0, width: a4.height, height: a4.width) : a4
      context.beginPage(mediaBox: &page)
      context.draw(image, in: fit(CGSize(width: image.width, height: image.height), in: page.insetBy(dx: 18, dy: 18)))
      context.endPage()
    }
    context.closePDF()
    return output as Data
  }

  /// Draws every page of `document` on top of the first page of `background` (e.g. letterhead).
  static func overlay(_ document: Data, on background: Data) throws -> Data {
    guard let pages = pdfDocument(document), let backgroundPage = pdfDocument(background)?.page(at: 1) else {
      return document
    }
    let output = NSMutableData()
    var box = a4
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return document }
    for number in 1...pages.numberOfPages {
      guard let page = pages.page(at: number) else { continue }
      var mediaBox = page.getBoxRect(.mediaBox)
      context.beginPage(mediaBox: &mediaBox)
      context.saveGState()
      context.concatenate(
        backgroundPage.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
      context.drawPDFPage(backgroundPage)
      context.restoreGState()
      context.drawPDFPage(page)
      context.endPage()
    }
    context.closePDF()
    return output as Data
  }

  /// Rasterises every page (white background) for on-screen preview.
  static func render(_ data: Data, width: Int) -> [Thumbnail] {
    guard let document = pdfDocument(data), document.numberOfPages > 0 else { return [] }
    return (1...document.numberOfPages).compactMap { number in
      guard let page = document.page(at: number) else { return nil }
      let box = page.getBoxRect(.mediaBox)
      let scale = CGFloat(width) / box.width
      let height = Int(box.height * scale)
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.scaleBy(x: scale, y: scale)
      context.translateBy(x: -box.minX, y: -box.minY)
      context.drawPDFPage(page)
      return context.makeImage().map(Thumbnail.init(image:))
    }
  }

  static func pdfDocument(_ data: Data) -> CGPDFDocument? {
    CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
  }

  static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
  }

  /// A sample invoice-like PDF for previews and screenshots.
  static func samplePDF(pages: Int = 3) -> Data {
    let output = NSMutableData()
    var box = a4
    let context = CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &box, nil)!
    for number in 0..<pages {
      context.beginPage(mediaBox: &box)
      context.setFillColor(CGColor(red: 0.12, green: 0.31, blue: 0.47, alpha: 1))
      context.fill(CGRect(x: 56, y: 760, width: 210, height: 22))
      context.setFillColor(CGColor(gray: 0.6, alpha: 1))
      for line in 0..<(22 - number * 3) {
        context.fill(CGRect(x: 56, y: 700 - line * 26, width: [480, 440, 470, 360, 460, 300][line % 6], height: 7))
      }
      context.endPage()
    }
    context.closePDF()
    return output as Data
  }

  /// A sample letterhead: coloured header band and footer rule.
  static func sampleLetterhead() -> Data {
    let output = NSMutableData()
    var box = a4
    let context = CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &box, nil)!
    context.beginPage(mediaBox: &box)
    context.setFillColor(CGColor(red: 0.12, green: 0.31, blue: 0.47, alpha: 1))
    context.fill(CGRect(x: 56, y: 790, width: 34, height: 34))
    context.fill(CGRect(x: 0, y: 778, width: box.width, height: 3))
    context.setFillColor(CGColor(gray: 0.75, alpha: 1))
    context.fill(CGRect(x: 56, y: 40, width: box.width - 112, height: 1))
    context.endPage()
    context.closePDF()
    return output as Data
  }
}
