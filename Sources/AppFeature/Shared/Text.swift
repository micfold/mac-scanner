import Foundation
import PrinterKit

// User-facing names for domain values. The UI is Czech; keeping every string here
// makes a later move to String Catalogs a mechanical change.

extension ScanSource {
  var label: String { self == .feeder ? "Podavač" : "Sklo" }
}

extension ScanColorMode {
  var label: String { self == .color ? "Barevně" : "Odstíny šedi" }
}

extension PaperSize {
  var label: String {
    switch self {
    case .a4: "A4"
    case .a5: "A5"
    case .letter: "Letter"
    case .legal: "Legal"
    }
  }
}

extension SplitMode {
  var label: String {
    switch self {
    case .single: "Celá dávka = 1 dokument"
    case .blankSeparator: "Podle prázdného listu"
    case .everyN: "Každých N stran"
    case .eachPage: "Každá strana zvlášť"
    }
  }
}

extension Sides {
  var label: String {
    switch self {
    case .oneSided: "Jednostranně"
    case .longEdge: "Oboustranně (dlouhá hrana)"
    case .shortEdge: "Oboustranně (krátká hrana)"
    }
  }
}

extension PrintColorMode {
  var label: String {
    switch self {
    case .auto: "Automaticky"
    case .color: "Barevně"
    case .monochrome: "Černobíle"
    }
  }
}

extension PrintQuality {
  var label: String {
    switch self {
    case .draft: "Koncept"
    case .normal: "Normální"
    case .high: "Vysoká"
    }
  }
}

extension Orientation {
  var label: String { self == .portrait ? "Na výšku" : "Na šířku" }
}

extension Scaling {
  var label: String {
    switch self {
    case .auto: "Automaticky"
    case .fit: "Přizpůsobit stránce"
    case .fill: "Vyplnit stránku"
    case .none: "Skutečná velikost"
    }
  }
}

extension PrinterState {
  var label: String {
    switch self {
    case .idle: "Připraveno"
    case .processing: "Tiskne"
    case .stopped: "Zastaveno"
    case .unknown: "Neznámý stav"
    }
  }
}

extension JobState {
  var label: String {
    switch self {
    case .pending: "Čeká"
    case .held: "Pozdrženo"
    case .processing: "Tiskne se"
    case .stopped: "Zastaveno"
    case .canceled: "Zrušeno"
    case .aborted: "Přerušeno"
    case .completed: "Hotovo"
    case .unknown: "—"
    }
  }
}

enum MediaText {
  static func name(_ keyword: String?) -> String {
    guard let keyword else { return "Výchozí" }
    guard let size = MediaSize(keyword: keyword) else { return keyword }
    let name = size.displayName
    return name.hasSuffix(" envelope") ? "Obálka " + name.dropLast(" envelope".count) : name
  }

  static func source(_ keyword: String?) -> String {
    switch keyword {
    case nil, "auto": "Automaticky"
    case let key? where key.hasPrefix("tray-"): "Zásobník " + key.dropFirst("tray-".count)
    case let key? where key.contains("by-pass") || key.contains("manual") || key.contains("multi"):
      "Víceúčelová přihrádka"
    case let key?: key
    }
  }

  static func type(_ keyword: String?) -> String? {
    switch keyword {
    case nil: nil
    case "stationery": "Běžný papír"
    case "envelope": "Obálky"
    case "labels": "Štítky"
    case "photographic", "photographic-glossy": "Fotopapír"
    case let key? where key.hasPrefix("cardstock"): "Karton"
    case let key?: key
    }
  }
}

enum StateReasonText {
  static func describe(_ reason: String) -> String {
    var key = reason
    for suffix in ["-error", "-warning", "-report"] where key.hasSuffix(suffix) {
      key = String(key.dropLast(suffix.count))
    }
    let known = [
      "media-empty": "Došel papír",
      "media-needed": "Vložte papír",
      "media-jam": "Zaseknutý papír",
      "media-low": "Dochází papír",
      "toner-low": "Dochází toner",
      "toner-empty": "Došel toner",
      "marker-supply-low": "Dochází spotřební materiál",
      "marker-supply-empty": "Došel spotřební materiál",
      "marker-waste-almost-full": "Odpadní nádobka je téměř plná",
      "marker-waste-full": "Odpadní nádobka je plná",
      "door-open": "Otevřená dvířka",
      "cover-open": "Otevřený kryt",
      "input-tray-missing": "Chybí zásobník",
      "output-area-full": "Výstupní přihrádka je plná",
      "paused": "Tiskárna je pozastavená",
      "offline": "Tiskárna je offline",
      "spool-area-full": "Plná paměť úloh",
    ]
    return known[key] ?? key.replacingOccurrences(of: "-", with: " ").capitalized
  }

  static func isError(_ reason: String) -> Bool { reason.hasSuffix("-error") || reason.contains("jam") }
}

enum ErrorText {
  static func describe(_ error: any Error) -> String {
    switch error {
    case let error as TransportError:
      switch error {
      case .unreachable(let host, _): return "Tiskárna \(host) neodpovídá. Je zapnutá a ve stejné síti?"
      case .cancelled: return "Zrušeno."
      }
    case let error as ESCLError:
      switch error {
      case .feederEmpty: return "Podavač je prázdný – vložte papíry lícem nahoru."
      case .feederProblem(let state): return feederProblem(state)
      case .busy: return "Skener je zaneprázdněný. Zkuste to za chvíli."
      case .noFeeder: return "Tento skener nemá podavač."
      case .jpegUnsupported: return "Skener neumí posílat stránky jako JPEG."
      case .noJobLocation: return "Skener nevrátil adresu úlohy."
      case .jobEnded(let state):
        return state == "Canceled" ? "Skenování bylo zrušeno na tiskárně." : "Skener úlohu ukončil bez stránek."
      case .http(let status, let operation):
        return status == 401 || status == 403
          ? "Skenování po síti je na tiskárně vypnuté nebo zamčené (HTTP \(status))."
          : "Skener odmítl požadavek \(operation) (HTTP \(status))."
      }
    case let error as IPPError:
      switch error {
      case .status(_, let message?): return "Tiskárna odmítla úlohu: \(message)"
      case .status(let code, nil): return "Tiskárna odmítla úlohu (kód 0x\(String(code, radix: 16)))."
      case .http(let status): return "Tiskárna odpověděla chybou HTTP \(status)."
      case .malformed: return "Tiskárna poslala nesrozumitelnou odpověď."
      }
    case let error as PrintServiceError:
      switch error {
      case .needsSystemQueue:
        return "Tiskárna nepřijímá PDF přímo. Vyberte v Nastavení tiskovou frontu macOS."
      case .systemPrintFailed(let output): return "Tisk přes macOS selhal: \(output)"
      }
    default:
      return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  static func feederProblem(_ state: FeederState) -> String {
    switch state {
    case .jammed: "V podavači se zasekl papír."
    case .open: "Podavač je otevřený."
    case .mispick: "Podavač nenabral papír."
    case .multipick: "Podavač nabral více listů najednou."
    case .other(let raw): "Podavač hlásí: \(raw)"
    case .loaded, .empty: ""
    }
  }
}

/// Czech plural: 1 strana, 2–4 strany, 5+ stran.
func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
  "\(count) " + (count == 1 ? one : (2...4).contains(count) ? few : many)
}
