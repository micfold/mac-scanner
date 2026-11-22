import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Vision
import UniformTypeIdentifiers
import ScanCore

/// Jedna naskenovaná stránka v dávce.
struct ScannedPage: Identifiable {
    let id = UUID()
    var seq = 0                 // pořadí v rámci celé dávky
    let jpeg: Data
    let dpi: Int
    let sheet: Int              // fyzický list (líc + rub mají stejný)
    let inkRatio: Double
    var isBlank: Bool
    var rotation = 0            // 0, 90, 180, 270 – po směru hodinových ručiček
    let thumbnail: CGImage
}

enum PageProcessor {
    static func make(jpeg: Data, requestedDPI: Int, sheet: Int, threshold: Double) throws -> ScannedPage {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let thumb = thumbnail(src, maxPixels: 420),
              let analysis = thumbnail(src, maxPixels: 900) else {
            if jpeg.starts(with: Data("%PDF".utf8)) {
                throw ESCLError.unsupported("Skener poslal PDF místo obrázku stránky.")
            }
            throw ESCLError.unsupported("Skener poslal stránku v nečitelném formátu.")
        }
        var dpi = requestedDPI
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let d = props[kCGImagePropertyDPIWidth] as? Double, d >= 100, d <= 1200 {
            dpi = Int(d.rounded())
        }
        let ink = inkRatio(analysis)
        return ScannedPage(jpeg: jpeg, dpi: dpi, sheet: sheet, inkRatio: ink,
                           isBlank: ink < threshold, thumbnail: thumb)
    }

    static func thumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Podíl plochy (bez okrajů) s tmavými body – „inkoustem“.
    /// Barvu papíru odhadujeme z nejsvětlejších 10 % bodů, takže recyklovaný / našedlý papír
    /// ani prosvítání zadní strany stránku za popsanou nepovažují.
    static func inkRatio(_ image: CGImage) -> Double {
        let w = 600
        let h = max(1, Int(Double(image.height) * Double(w) / Double(max(1, image.width))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return 1 }
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h)
        let mx = w * 6 / 100, my = h * 6 / 100
        var hist = [Int](repeating: 0, count: 256)
        var total = 0
        for y in my..<(h - my) {
            let row = y * w
            for x in mx..<(w - mx) { hist[Int(px[row + x])] += 1 }
            total += w - 2 * mx
        }
        guard total > 0 else { return 1 }
        var acc = 0, paper = 255
        for v in stride(from: 255, through: 0, by: -1) {
            acc += hist[v]
            if acc >= total / 10 { paper = v; break }
        }
        let cutoff = max(0, paper - 60)
        let ink = hist[0..<cutoff].reduce(0, +)
        return Double(ink) / Double(total)
    }
}

// MARK: - Export

enum ExportError: LocalizedError {
    case cannotCreate(URL)
    case badImage
    var errorDescription: String? {
        switch self {
        case .cannotCreate(let u): return "Nelze vytvořit soubor \(u.lastPathComponent)."
        case .badImage: return "Stránku se nepodařilo načíst."
        }
    }
}

enum Exporter {
    struct PageInput: Sendable {
        let jpeg: Data
        let rotation: Int
        let dpi: Int
    }

    static func export(_ pages: [PageInput], baseName: String, folder: URL,
                       format: OutputFormat, ocr: Bool) throws -> [URL] {
        switch format {
        case .pdf:
            let url = FileNamer.uniqueURL(in: folder, base: baseName, ext: "pdf")
            try writePDF(pages, to: url, ocr: ocr)
            return [url]
        case .jpeg:
            return try pages.enumerated().map { i, p in
                let name = pages.count == 1 ? baseName : "\(baseName)-\(i + 1)"
                let url = FileNamer.uniqueURL(in: folder, base: name, ext: "jpg")
                try writeJPEG(p, to: url)
                return url
            }
        }
    }

    // MARK: PDF (JPEG se vkládá beze změny, OCR text jako neviditelná vrstva)

    static func writePDF(_ pages: [PageInput], to url: URL, ocr: Bool) throws {
        let info = [kCGPDFContextCreator as String: "Skener"] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, info) else { throw ExportError.cannotCreate(url) }
        for p in pages {
            guard let provider = CGDataProvider(data: p.jpeg as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else {
                ctx.closePDF()
                throw ExportError.badImage
            }
            let dpi = CGFloat(p.dpi > 0 ? p.dpi : 300)
            let w = CGFloat(image.width) * 72 / dpi
            let h = CGFloat(image.height) * 72 / dpi
            let rot = ((p.rotation % 360) + 360) % 360
            let pageSize = (rot == 90 || rot == 270) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

            var box = CGRect(origin: .zero, size: pageSize)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            ctx.saveGState()
            switch rot {
            case 90:  ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)
            case 180: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
            case 270: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)
            default: break
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()

            if ocr {
                drawInvisibleText(recognizeText(image, rotation: rot), in: ctx, pageSize: pageSize)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Rozpoznaný text s rámečky v normalizovaných souřadnicích (počátek vlevo dole, jako v PDF).
    static func recognizeText(_ image: CGImage, rotation: Int) -> [(String, CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if let supported = try? req.supportedRecognitionLanguages() {
            let wanted = ["cs-CZ", "sk-SK", "en-US", "de-DE"].filter { supported.contains($0) }
            if wanted.contains("cs-CZ") {
                req.recognitionLanguages = wanted
            } else {
                req.automaticallyDetectsLanguage = true
            }
        }
        let orientation: CGImagePropertyOrientation
        switch rotation {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            return (c.string, obs.boundingBox)
        }
    }

    static func drawInvisibleText(_ items: [(String, CGRect)], in ctx: CGContext, pageSize: CGSize) {
        guard !items.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for (text, bb) in items {
            let r = CGRect(x: bb.minX * pageSize.width, y: bb.minY * pageSize.height,
                           width: bb.width * pageSize.width, height: bb.height * pageSize.height)
            guard r.width > 1, r.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.85, nil)
            let attr = NSAttributedString(string: text,
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard lineWidth > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.2)
            ctx.scaleBy(x: r.width / CGFloat(lineWidth), y: 1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: JPEG (otočení se zapíše bezeztrátově jako EXIF orientace)

    static func writeJPEG(_ p: PageInput, to url: URL) throws {
        let rot = ((p.rotation % 360) + 360) % 360
        if rot == 0 { try p.jpeg.write(to: url); return }
        let orientation: CGImagePropertyOrientation = rot == 90 ? .right : (rot == 180 ? .down : .left)
        guard let src = CGImageSourceCreateWithData(p.jpeg as CFData, nil),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreate(url)
        }
        let opts = [kCGImageDestinationOrientation as String: orientation.rawValue] as CFDictionary
        if !CGImageDestinationCopyImageSource(dst, src, opts, nil) {
            try p.jpeg.write(to: url)
        }
    }
}
