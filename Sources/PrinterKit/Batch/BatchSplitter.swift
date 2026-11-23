import Foundation

public enum SplitMode: String, Codable, CaseIterable, Sendable, Identifiable {
  /// The whole batch is one document.
  case single
  /// A blank sheet separates documents.
  case blankSeparator
  /// A new document every N pages.
  case everyN
  /// Every page is its own document.
  case eachPage
  public var id: String { rawValue }
}

public struct SplitOptions: Codable, Equatable, Sendable {
  public var mode: SplitMode
  public var everyN: Int
  public var removeBlankPages: Bool

  public init(mode: SplitMode = .blankSeparator, everyN: Int = 2, removeBlankPages: Bool = true) {
    self.mode = mode
    self.everyN = everyN
    self.removeBlankPages = removeBlankPages
  }
}

/// What splitting needs to know about a scanned page.
public struct PageMeta: Sendable, Equatable {
  public var isBlank: Bool
  /// Pages of the same physical sheet (front + back in duplex) share a `sheet` number.
  public var sheet: Int

  public init(isBlank: Bool, sheet: Int) {
    self.isBlank = isBlank
    self.sheet = sheet
  }
}

public enum BatchSplitter {
  /// Groups page indices into documents. Empty documents are dropped.
  ///
  /// In `blankSeparator` mode the unit is the physical sheet: only a sheet that is blank on
  /// *both* sides separates documents, so the blank back of a single-sided original never
  /// splits a document (it is just removed when `removeBlankPages` is on).
  public static func split(_ pages: [PageMeta], options: SplitOptions) -> [[Int]] {
    let keep: (Int) -> Bool = { !(options.removeBlankPages && pages[$0].isBlank) }
    let documents: [[Int]]

    switch options.mode {
    case .single:
      documents = [pages.indices.filter(keep)]
    case .eachPage:
      documents = pages.indices.filter(keep).map { [$0] }
    case .everyN:
      let kept = pages.indices.filter(keep)
      let size = max(1, options.everyN)
      documents = stride(from: 0, to: kept.count, by: size).map { Array(kept[$0..<min($0 + size, kept.count)]) }
    case .blankSeparator:
      var result: [[Int]] = [[]]
      for sheet in sheets(of: pages) {
        if sheet.allSatisfy({ pages[$0].isBlank }) {
          result.append([])
        } else {
          result[result.count - 1] += sheet.filter(keep)
        }
      }
      documents = result
    }
    return documents.filter { !$0.isEmpty }
  }

  /// Consecutive page indices that share a sheet number.
  static func sheets(of pages: [PageMeta]) -> [[Int]] {
    var sheets: [[Int]] = []
    for index in pages.indices {
      if let last = sheets.last?.last, pages[last].sheet == pages[index].sheet {
        sheets[sheets.count - 1].append(index)
      } else {
        sheets.append([index])
      }
    }
    return sheets
  }
}

/// File names from a pattern. Tokens: `{date}` `{time}` `{n}` (Czech aliases `{datum}` `{čas}` `{č}`).
public struct FileNamer: Sendable {
  public var pattern: String

  public init(pattern: String) { self.pattern = pattern }

  public var usesCounter: Bool { ["{n}", "{č}", "{c}"].contains { pattern.contains($0) } }

  public func name(index: Int, date: Date = Date()) -> String {
    let day = Self.format(date, "yyyy-MM-dd")
    let time = Self.format(date, "HH-mm")
    let replacements = [
      "{date}": day, "{datum}": day,
      "{time}": time, "{čas}": time, "{cas}": time,
      "{n}": String(index), "{č}": String(index), "{c}": String(index),
    ]
    var name = pattern.isEmpty ? "Scan_{date}_{n}" : pattern
    for (token, value) in replacements { name = name.replacingOccurrences(of: token, with: value) }
    return Self.sanitize(name)
  }

  public static func sanitize(_ name: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\\0")
    let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty { return "Scan" }
    return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
  }

  /// A URL in `folder` that does not exist yet (appends " (2)", " (3)" … when needed).
  public static func uniqueURL(
    in folder: URL, base: String, ext: String,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> URL {
    var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
    var counter = 2
    while exists(url) {
      url = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
      counter += 1
    }
    return url
  }

  private static func format(_ date: Date, _ format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
