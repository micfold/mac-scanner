import Foundation
import Testing

@testable import PrinterKit

@Suite("Batch splitting")
struct BatchSplitterTests {
  /// Duplex batch from sheet descriptions, e.g. ["XX", "X_", "__"] (X = content, _ = blank).
  func duplex(_ sheets: [String]) -> [PageMeta] {
    sheets.enumerated().flatMap { index, sheet in sheet.map { PageMeta(isBlank: $0 == "_", sheet: index) } }
  }

  func simplex(_ pages: String) -> [PageMeta] {
    pages.enumerated().map { PageMeta(isBlank: $1 == "_", sheet: $0) }
  }

  @Test func blankBackDoesNotSplitDuplex() {
    #expect(BatchSplitter.split(duplex(["X_", "X_"]), options: SplitOptions(mode: .blankSeparator)) == [[0, 2]])
  }

  @Test func blankSheetSeparatesDuplex() {
    let pages = duplex(["XX", "X_", "__", "XX", "__", "__", "X_"])
    #expect(BatchSplitter.split(pages, options: SplitOptions(mode: .blankSeparator)) == [[0, 1, 2], [6, 7], [12]])
  }

  @Test func keepsBlankPagesWhenAsked() {
    let options = SplitOptions(mode: .blankSeparator, removeBlankPages: false)
    #expect(BatchSplitter.split(duplex(["X_", "__", "XX"]), options: options) == [[0, 1], [4, 5]])
  }

  @Test func simplexSeparator() {
    #expect(
      BatchSplitter.split(simplex("XX_X__XX"), options: SplitOptions(mode: .blankSeparator)) == [[0, 1], [3], [6, 7]])
  }

  @Test func otherModes() {
    let pages = simplex("XX_XX")
    #expect(BatchSplitter.split(pages, options: SplitOptions(mode: .single)) == [[0, 1, 3, 4]])
    #expect(BatchSplitter.split(pages, options: SplitOptions(mode: .eachPage)) == [[0], [1], [3], [4]])
    #expect(BatchSplitter.split(pages, options: SplitOptions(mode: .everyN, everyN: 3)) == [[0, 1, 3], [4]])
    #expect(BatchSplitter.split([], options: SplitOptions(mode: .single)) == [])
  }
}

@Suite("File naming")
struct FileNamerTests {
  let date: Date = {
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour, components.minute) = (2026, 11, 22, 9, 5)
    return Calendar(identifier: .gregorian).date(from: components)!
  }()

  @Test func patterns() {
    #expect(FileNamer(pattern: "Invoice_{date}_{n}").name(index: 3, date: date) == "Invoice_2026-11-22_3")
    #expect(FileNamer(pattern: "Faktura_{datum}_{č}").name(index: 1, date: date) == "Faktura_2026-11-22_1")
    #expect(FileNamer(pattern: "{date} {time}/x").name(index: 1, date: date) == "2026-11-22 09-05-x")
    #expect(FileNamer(pattern: "").name(index: 1, date: date) == "Scan_2026-11-22_1")
  }

  @Test func uniqueURL() {
    let taken: Set<String> = ["/tmp/x/A.pdf", "/tmp/x/A (2).pdf"]
    let url = FileNamer.uniqueURL(in: URL(fileURLWithPath: "/tmp/x"), base: "A", ext: "pdf") { taken.contains($0.path) }
    #expect(url.lastPathComponent == "A (3).pdf")
  }
}
