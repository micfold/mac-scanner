import AppKit
import Foundation
import Observation
import PrinterKit
import UniformTypeIdentifiers

/// Printing: queued files, the ticket built from presets and printer capabilities, and submission.
@MainActor
@Observable
public final class PrintModel {
  private(set) var documents: [PrintDocument] = []
  var selectedID: UUID? { didSet { updatePageRanges() } }

  var presets: [PrintPreset] { didSet { preferences.printPresets = presets } }
  /// `nil` once the ticket was edited by hand.
  private(set) var activePresetID: UUID?
  var ticket = PrintTicket() {
    didSet { if ticket != presets.first(where: { $0.id == activePresetID })?.ticket { activePresetID = nil } }
  }
  var pageRangeText = "" { didSet { updatePageRanges() } }
  private(set) var pageRangeIsValid = true

  private(set) var letterhead: (name: String, data: Data)?
  private(set) var isPrinting = false
  var banner: Banner?

  private let session: DeviceSession
  private let preferences: Preferences

  public init(session: DeviceSession, preferences: Preferences) {
    self.session = session
    self.preferences = preferences
    presets = preferences.printPresets ?? PrintPreset.defaults
    activePresetID = presets.first?.id
  }

  // MARK: Derived

  var selected: PrintDocument? { documents.first { $0.id == selectedID } ?? documents.first }
  var capabilities: PrintCapabilities? { session.printer?.capabilities }

  /// The PDF that will be sent for the selected document (with letterhead), for the preview.
  var previewPDF: Data? {
    guard let selected else { return nil }
    guard let letterhead else { return selected.pdf }
    return (try? PrintComposer.overlay(selected.pdf, on: letterhead.data)) ?? selected.pdf
  }

  var sidesOptions: [Sides] { nonEmpty(capabilities?.sides, Sides.allCases) }
  var colorOptions: [PrintColorMode] { nonEmpty(capabilities?.colorModes, PrintColorMode.allCases) }
  var qualityOptions: [PrintQuality] { nonEmpty(capabilities?.qualities, PrintQuality.allCases) }
  var numberUpOptions: [Int] { nonEmpty(capabilities?.numberUp, [1, 2, 4, 6, 9, 16]) }
  var mediaOptions: [String] { nonEmpty(capabilities?.media, ["iso_a4_210x297mm", "iso_a5_148x210mm"]) }
  var sourceOptions: [String] { (capabilities?.sources ?? []).filter { $0 != "auto" } }
  var scalingOptions: [Scaling] { nonEmpty(capabilities?.scaling, Scaling.allCases) }
  var maxCopies: Int { min(capabilities?.copies.upperBound ?? 99, 999) }
  var sheetsEstimate: Int? {
    guard let selected else { return nil }
    let pages =
      ticket.pageRanges.isEmpty
      ? selected.pageCount
      : ticket.pageRanges.reduce(0) { $0 + min($1.upperBound, selected.pageCount) - $1.lowerBound + 1 }
    let faces = (pages + ticket.numberUp - 1) / ticket.numberUp
    return (ticket.sides == .oneSided ? faces : (faces + 1) / 2) * ticket.copies
  }

  /// How the job will travel to the printer.
  var routeDescription: String {
    if capabilities?.acceptsPDF ?? true { return "Tiskne se přímo přes IPP – bez ovladače." }
    if let queue = session.cupsQueue { return "Tiskne se přes frontu macOS „\(queue)“." }
    return "Tiskárna nepřijímá PDF přímo – vyberte v Nastavení frontu macOS."
  }

  var canPrint: Bool { selected != nil && pageRangeIsValid && !isPrinting && !session.address.isEmpty }

  private func nonEmpty<T>(_ values: [T]?, _ fallback: [T]) -> [T] {
    guard let values, !values.isEmpty else { return fallback }
    return values
  }

  // MARK: Documents

  func add(_ urls: [URL]) {
    Task {
      for url in urls {
        do {
          let document = try await Task.detached(priority: .userInitiated) { try PrintComposer.document(from: url) }
            .value
          documents.append(document)
          if selectedID == nil { selectedID = document.id }
        } catch {
          banner = Banner(kind: .error, text: ErrorText.describe(error))
        }
      }
    }
  }

  func remove(_ id: UUID) {
    documents.removeAll { $0.id == id }
    if selectedID == id { selectedID = documents.first?.id }
  }

  public func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.pdf, .image]
    if panel.runModal() == .OK { add(panel.urls) }
  }

  func chooseLetterhead() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.message = "Vyberte PDF s hlavičkovým papírem (použije se jeho první strana)."
    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
      letterhead = (url.deletingPathExtension().lastPathComponent, data)
    }
  }

  func removeLetterhead() { letterhead = nil }

  // MARK: Ticket

  func apply(_ preset: PrintPreset) {
    ticket = preset.ticket
    pageRangeText = ""
    activePresetID = preset.id
  }

  func isActive(_ preset: PrintPreset) -> Bool { activePresetID == preset.id }

  func saveAsPreset(named name: String) {
    let preset = PrintPreset(name: name, symbol: "star", ticket: ticket)
    presets.append(preset)
    activePresetID = preset.id
  }

  private func updatePageRanges() {
    if let ranges = PrintTicket.parsePageRanges(pageRangeText, pageCount: selected?.pageCount ?? .max) {
      pageRangeIsValid = true
      ticket.pageRanges = ranges
    } else {
      pageRangeIsValid = false
    }
  }

  // MARK: Printing

  func print(all: Bool = false) {
    let targets = all ? documents : selected.map { [$0] } ?? []
    guard !targets.isEmpty, canPrint else { return }
    let printer = session.services.printer
    let ticket = self.ticket
    let capabilities = self.capabilities
    let background = letterhead?.data
    isPrinting = true
    banner = nil

    Task {
      var sent: [String] = []
      do {
        for document in targets {
          let pdf = try background.map { try PrintComposer.overlay(document.pdf, on: $0) } ?? document.pdf
          sent.append(try await printer.print(pdf, jobName: document.name, ticket: ticket, capabilities: capabilities))
          session.log.append("Tisk „\(document.name)“ → úloha \(sent.last ?? "?")")
        }
        banner = Banner(
          kind: .success,
          text: targets.count == 1
            ? "Odesláno na tiskárnu (úloha \(sent[0]))."
            : "Odesláno \(plural(targets.count, "dokument", "dokumenty", "dokumentů")).")
      } catch {
        banner = Banner(kind: .error, text: ErrorText.describe(error))
      }
      isPrinting = false
    }
  }

  // MARK: Preview support

  func loadSample() {
    let pdf = PrintComposer.samplePDF()
    documents = [
      PrintDocument(url: URL(fileURLWithPath: "/Nabidka_klient.pdf"), pdf: pdf, pageCount: 3),
      PrintDocument(
        url: URL(fileURLWithPath: "/Podklady_schuzka.pdf"), pdf: PrintComposer.samplePDF(pages: 7), pageCount: 7),
      PrintDocument(
        url: URL(fileURLWithPath: "/Smlouva_najem.pdf"), pdf: PrintComposer.samplePDF(pages: 4), pageCount: 4),
    ]
    selectedID = documents[0].id
    letterhead = ("Hlavičkový papír", PrintComposer.sampleLetterhead())
    if let preset = presets.first(where: { $0.name == "Oboustranně" }) { apply(preset) }
  }
}
