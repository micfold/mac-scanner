import Foundation

public enum SplitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case single          // celá dávka = 1 dokument
    case blankSeparator  // prázdný list odděluje dokumenty
    case everyN          // každých N stran nový dokument
    case eachPage        // každá strana zvlášť
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .single: "Celá dávka = 1 dokument"
        case .blankSeparator: "Podle prázdného listu"
        case .everyN: "Každých N stran"
        case .eachPage: "Každá strana zvlášť"
        }
    }
}

public struct SplitOptions: Codable, Equatable, Sendable {
    public var mode: SplitMode
    public var everyN: Int
    public var removeBlankPages: Bool

    public init(mode: SplitMode = .blankSeparator, everyN: Int = 2, removeBlankPages: Bool = true) {
        self.mode = mode; self.everyN = everyN; self.removeBlankPages = removeBlankPages
    }
}

/// Co o stránce potřebuje dělení vědět.
public struct PageMeta: Sendable, Equatable {
    public var isBlank: Bool
    /// Stránky stejného fyzického listu (líc + rub při oboustranném skenu) mají stejné `sheet`.
    public var sheet: Int
    public init(isBlank: Bool, sheet: Int) { self.isBlank = isBlank; self.sheet = sheet }
}

public enum DocumentSplitter {
    /// Rozdělí stránky na dokumenty. Vrací indexy stránek pro každý dokument; prázdné dokumenty vynechá.
    ///
    /// Režim „podle prázdného listu“ pracuje s celými listy: oddělovač je list, který je prázdný
    /// z obou stran. Prázdný rub jednostranného originálu tedy dokument nerozdělí – jen se zahodí
    /// (pokud je zapnuté odstraňování prázdných stran).
    public static func split(_ pages: [PageMeta], options: SplitOptions) -> [[Int]] {
        // seskupit po sobě jdoucí stránky do listů
        var sheets: [[Int]] = []
        for (i, p) in pages.enumerated() {
            if let last = sheets.last?.last, pages[last].sheet == p.sheet { sheets[sheets.count - 1].append(i) }
            else { sheets.append([i]) }
        }

        func keep(_ i: Int) -> Bool { !(options.removeBlankPages && pages[i].isBlank) }

        var docs: [[Int]] = []
        switch options.mode {
        case .single:
            docs = [pages.indices.filter(keep)]

        case .eachPage:
            docs = pages.indices.filter(keep).map { [$0] }

        case .everyN:
            let n = max(1, options.everyN)
            let kept = pages.indices.filter(keep)
            docs = stride(from: 0, to: kept.count, by: n).map { Array(kept[$0..<min($0 + n, kept.count)]) }

        case .blankSeparator:
            var current: [Int] = []
            for sheet in sheets {
                if sheet.allSatisfy({ pages[$0].isBlank }) {
                    docs.append(current)
                    current = []
                } else {
                    current.append(contentsOf: sheet.filter(keep))
                }
            }
            docs.append(current)
        }
        return docs.filter { !$0.isEmpty }
    }
}
