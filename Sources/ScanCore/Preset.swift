import Foundation

public enum OutputFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case pdf, jpeg
    public var id: String { rawValue }
    public var label: String { self == .pdf ? "PDF" : "JPEG (každá strana zvlášť)" }
}

/// Předvolba = vše, co je potřeba k jednomu typu skenování.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var scan: ScanSettings
    public var split: SplitOptions
    public var ocr: Bool
    public var output: OutputFormat
    public var namePattern: String
    /// Cílová složka; `~` se rozbalí na domovskou složku.
    public var folder: String
    /// Práh prázdné strany: podíl plochy s „inkoustem“, pod kterým je strana prázdná (0.0003–0.01).
    public var blankThreshold: Double

    public init(id: UUID = UUID(), name: String, scan: ScanSettings = ScanSettings(),
                split: SplitOptions = SplitOptions(), ocr: Bool = true, output: OutputFormat = .pdf,
                namePattern: String = "Sken_{datum}_{č}", folder: String = "~/Documents/Skeny",
                blankThreshold: Double = 0.0015) {
        self.id = id; self.name = name; self.scan = scan; self.split = split; self.ocr = ocr
        self.output = output; self.namePattern = namePattern; self.folder = folder
        self.blankThreshold = blankThreshold
    }

    public var folderURL: URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static let defaults: [Preset] = [
        Preset(name: "Faktury",
               scan: ScanSettings(source: .feeder, duplex: true, colorMode: .color, resolution: 300),
               split: SplitOptions(mode: .blankSeparator, removeBlankPages: true),
               namePattern: "Faktura_{datum}_{č}", folder: "~/Documents/Skeny/Faktury"),
        Preset(name: "Smlouvy",
               scan: ScanSettings(source: .feeder, duplex: true, colorMode: .gray, resolution: 300),
               split: SplitOptions(mode: .single, removeBlankPages: true),
               namePattern: "Smlouva_{datum}_{č}", folder: "~/Documents/Skeny/Smlouvy"),
        Preset(name: "Účtenky",
               scan: ScanSettings(source: .platen, duplex: false, colorMode: .color, resolution: 300),
               split: SplitOptions(mode: .eachPage, removeBlankPages: true),
               namePattern: "Uctenka_{datum}_{č}", folder: "~/Documents/Skeny/Uctenky"),
        Preset(name: "Fotky",
               scan: ScanSettings(source: .platen, duplex: false, colorMode: .color, resolution: 300),
               split: SplitOptions(mode: .eachPage, removeBlankPages: false),
               ocr: false, output: .jpeg,
               namePattern: "Foto_{datum}_{č}", folder: "~/Pictures/Skeny"),
    ]
}

/// Pojmenování souborů podle vzoru. Zástupné znaky: {datum} {čas} {č} (nebo {date} {time} {n}).
public struct FileNamer: Sendable {
    public var pattern: String
    public init(pattern: String) { self.pattern = pattern }

    public func name(index: Int, date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH-mm"
        var s = pattern.isEmpty ? "Sken_{datum}_{č}" : pattern
        for (token, value) in [("{datum}", df.string(from: date)), ("{date}", df.string(from: date)),
                               ("{čas}", tf.string(from: date)), ("{cas}", tf.string(from: date)),
                               ("{time}", tf.string(from: date)),
                               ("{č}", String(index)), ("{c}", String(index)), ("{n}", String(index))] {
            s = s.replacingOccurrences(of: token, with: value)
        }
        return Self.sanitize(s)
    }

    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(".") ? "_" + trimmed : (trimmed.isEmpty ? "Sken" : trimmed)
    }

    /// Vrátí URL, které ještě neexistuje (přidá „ (2)“, „ (3)“… pokud je potřeba).
    public static func uniqueURL(in folder: URL, base: String, ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
