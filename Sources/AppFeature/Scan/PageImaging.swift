import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PrinterKit
import UniformTypeIdentifiers
@preconcurrency import Vision

/// `CGImage` is immutable and thread-safe; this wrapper lets it cross actors.
struct Thumbnail: @unchecked Sendable {
  let image: CGImage
}

/// One scanned page in the batch.
struct ScannedPage: Identifiable, Sendable {
  let id = UUID()
  var sequence = 0
  let jpeg: Data
  let dpi: Int
  /// Front and back of one physical sheet share this number.
  let sheet: Int
  let inkRatio: Double
  var isBlank: Bool
  /// Clockwise, multiple of 90.
  var rotation = 0
  let thumbnail: Thumbnail
}

enum PageImagingError: Error {
  case unreadable
}

enum PageImaging {
  /// Decodes a scanned JPEG, makes a thumbnail and measures how much of the page has ink.
  static func page(from jpeg: Data, requestedDPI: Int, sheet: Int, blankThreshold: Double) throws -> ScannedPage {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let preview = Self.thumbnail(source, maxPixels: 420),
      let analysis = Self.thumbnail(source, maxPixels: 900)
    else { throw PageImagingError.unreadable }

    var dpi = requestedDPI
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let reported = properties[kCGImagePropertyDPIWidth] as? Double, (100...1200).contains(reported)
    {
      dpi = Int(reported.rounded())
    }
    let ink = inkRatio(analysis)
    return ScannedPage(
      jpeg: jpeg, dpi: dpi, sheet: sheet, inkRatio: ink, isBlank: ink < blankThreshold,
      thumbnail: Thumbnail(image: preview))
  }

  static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Share of the page (margins excluded) that is clearly darker than the paper.
  /// Paper brightness is estimated from the brightest 10 % of pixels, so grey recycled
  /// paper and show-through from the back side do not count as content.
  static func inkRatio(_ image: CGImage) -> Double {
    let width = 600
    let height = max(1, image.height * width / max(1, image.width))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return 1 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return 1 }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

    let marginX = width * 6 / 100
    let marginY = height * 6 / 100
    var histogram = [Int](repeating: 0, count: 256)
    var total = 0
    for y in marginY..<(height - marginY) {
      for x in marginX..<(width - marginX) { histogram[Int(pixels[y * width + x])] += 1 }
      total += width - 2 * marginX
    }
    guard total > 0 else { return 1 }

    var brightest = 0
    var paper = 255
    for level in stride(from: 255, through: 0, by: -1) {
      brightest += histogram[level]
      if brightest >= total / 10 {
        paper = level
        break
      }
    }
    let ink = histogram[0..<max(0, paper - 60)].reduce(0, +)
    return Double(ink) / Double(total)
  }
}

// MARK: - Export

enum ScanExporter {
  struct Page: Sendable {
    let jpeg: Data
    let rotation: Int
    let dpi: Int
  }

  static func export(_ pages: [Page], name: String, folder: URL, format: OutputFormat, ocr: Bool) throws -> [URL] {
    switch format {
    case .pdf:
      let url = FileNamer.uniqueURL(in: folder, base: name, ext: "pdf")
      try writePDF(pages, to: url, ocr: ocr)
      return [url]
    case .jpeg:
      return try pages.enumerated().map { index, page in
        let base = pages.count == 1 ? name : "\(name)-\(index + 1)"
        let url = FileNamer.uniqueURL(in: folder, base: base, ext: "jpg")
        try writeJPEG(page, to: url)
        return url
      }
    }
  }

  /// JPEGs are embedded unchanged; OCR text goes on an invisible layer so the PDF is searchable.
  static func writePDF(_ pages: [Page], to url: URL, ocr: Bool) throws {
    guard
      let context = CGContext(
        url as CFURL, mediaBox: nil, [kCGPDFContextCreator as String: "Skener"] as CFDictionary)
    else { throw CocoaError(.fileWriteUnknown) }
    defer { context.closePDF() }

    for page in pages {
      guard let provider = CGDataProvider(data: page.jpeg as CFData),
        let image = CGImage(
          jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { throw PageImagingError.unreadable }
      let dpi = CGFloat(page.dpi > 0 ? page.dpi : 300)
      let width = CGFloat(image.width) * 72 / dpi
      let height = CGFloat(image.height) * 72 / dpi
      let rotation = (page.rotation % 360 + 360) % 360
      let sideways = rotation == 90 || rotation == 270
      var mediaBox = CGRect(x: 0, y: 0, width: sideways ? height : width, height: sideways ? width : height)
      let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
      context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

      context.saveGState()
      switch rotation {
      case 90:
        context.translateBy(x: 0, y: width)
        context.rotate(by: -.pi / 2)
      case 180:
        context.translateBy(x: width, y: height)
        context.rotate(by: .pi)
      case 270:
        context.translateBy(x: height, y: 0)
        context.rotate(by: .pi / 2)
      default:
        break
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      context.restoreGState()

      if ocr { drawInvisibleText(recognizeText(image, rotation: rotation), in: context, size: mediaBox.size) }
      context.endPDFPage()
    }
  }

  /// Text lines with boxes in normalised coordinates (origin bottom-left, like PDF).
  static func recognizeText(_ image: CGImage, rotation: Int) -> [(String, CGRect)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let supported = try? request.supportedRecognitionLanguages(), supported.contains("cs-CZ") {
      request.recognitionLanguages = ["cs-CZ", "sk-SK", "en-US", "de-DE"].filter(supported.contains)
    } else {
      request.automaticallyDetectsLanguage = true
    }
    let orientation: CGImagePropertyOrientation =
      switch rotation {
      case 90: .right
      case 180: .down
      case 270: .left
      default: .up
      }
    do {
      try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    } catch {
      return []
    }
    return (request.results ?? []).compactMap { observation in
      observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
    }
  }

  static func drawInvisibleText(_ lines: [(String, CGRect)], in context: CGContext, size: CGSize) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setTextDrawingMode(.invisible)
    for (text, box) in lines {
      let rect = CGRect(
        x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width,
        height: box.height * size.height)
      guard rect.width > 1, rect.height > 1 else { continue }
      let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
      let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
      guard lineWidth > 0 else { continue }
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
      context.scaleBy(x: rect.width / lineWidth, y: 1)
      context.textPosition = .zero
      CTLineDraw(line, context)
      context.restoreGState()
    }
  }

  /// Rotation is stored losslessly as EXIF orientation.
  static func writeJPEG(_ page: Page, to url: URL) throws {
    let rotation = (page.rotation % 360 + 360) % 360
    guard rotation != 0,
      let source = CGImageSourceCreateWithData(page.jpeg as CFData, nil),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      try page.jpeg.write(to: url)
      return
    }
    let orientation: CGImagePropertyOrientation = rotation == 90 ? .right : rotation == 180 ? .down : .left
    let options = [kCGImageDestinationOrientation as String: orientation.rawValue] as CFDictionary
    if !CGImageDestinationCopyImageSource(destination, source, options, nil) { try page.jpeg.write(to: url) }
  }
}
