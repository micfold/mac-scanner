import AppKit
import Foundation
import Observation
import PrinterKit

/// A document in the current batch: an ordered list of page ids.
struct ScanDocument: Identifiable, Equatable {
  let id = UUID()
  var pageIDs: [UUID]
  var customName: String?
}

/// Batch scanning: presets, the batch being built, manual fixes and saving.
@MainActor
@Observable
public final class ScanModel {
  enum Phase: Equatable {
    case idle
    case scanning(pages: Int)
    case saving(done: Int, total: Int)
  }

  // Presets
  var presets: [ScanPreset] { didSet { preferences.scanPresets = presets } }
  var selectedPresetID: UUID { didSet { preferences.selectedScanPreset = selectedPresetID } }
  var preset: ScanPreset {
    get { presets.first { $0.id == selectedPresetID } ?? presets[0] }
    set {
      if let index = presets.firstIndex(where: { $0.id == newValue.id }) { presets[index] = newValue }
    }
  }

  // Batch
  private(set) var pages: [UUID: ScannedPage] = [:]
  private(set) var documents: [ScanDocument] = []
  private(set) var removedPageIDs: [UUID] = []
  private(set) var livePageIDs: [UUID] = []
  private(set) var phase: Phase = .idle
  var banner: Banner?
  var previewPageID: UUID?
  var revealAfterSave: Bool { didSet { preferences.revealAfterSave = revealAfterSave } }

  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var nextSheet = 0
  @ObservationIgnored private var nextSequence = 0
  private let session: DeviceSession
  private let preferences: Preferences

  public init(session: DeviceSession, preferences: Preferences) {
    self.session = session
    self.preferences = preferences
    let presets = preferences.scanPresets ?? ScanPreset.defaults
    self.presets = presets
    selectedPresetID =
      preferences.selectedScanPreset.flatMap { id in presets.first { $0.id == id }?.id } ?? presets[0].id
    revealAfterSave = preferences.revealAfterSave
  }

  // MARK: Derived

  var isBusy: Bool { phase != .idle }
  var isScanning: Bool { if case .scanning = phase { true } else { false } }
  var pageCount: Int { documents.reduce(0) { $0 + $1.pageIDs.count } }
  var isEmpty: Bool { documents.isEmpty && livePageIDs.isEmpty && removedPageIDs.isEmpty }

  var inputCaps: InputCaps? {
    session.scannerCapabilities?.caps(for: preset.scan.source, duplex: preset.scan.isDuplex)
  }

  /// Resolutions the scanner supports for the current source (plus the preset's own value).
  var resolutions: [Int] {
    var values = inputCaps?.resolutions.filter { (100...600).contains($0) } ?? []
    if values.isEmpty { values = [150, 300, 600] }
    if !values.contains(preset.scan.resolution) { values.append(preset.scan.resolution) }
    return values.sorted()
  }

  var effectiveResolution: Int { inputCaps?.nearestResolution(to: preset.scan.resolution) ?? preset.scan.resolution }

  func plannedName(index: Int) -> String { FileNamer(pattern: preset.namePattern).name(index: index + 1) }

  // MARK: Scanning

  /// Scans into the batch. With `intoLast`, the first new document is appended to the last one.
  func scan(intoLast: Bool = false) {
    guard !isBusy else { return }
    guard session.address.isEmpty == false else {
      banner = Banner(kind: .error, text: "Nejdřív v Nastavení vyberte tiskárnu.")
      return
    }
    banner = nil
    let preset = self.preset
    let scanner = session.services.scanner
    let capabilities = session.scannerCapabilities
    let dpi = effectiveResolution
    let duplex = preset.scan.isDuplex
    let firstSheet = nextSheet
    livePageIDs = []
    phase = .scanning(pages: 0)
    session.busyCount += 1
    session.log.append("=== Skenování „\(preset.name)“: \(preset.scan.source.label), \(dpi) dpi ===")

    scanTask = Task {
      var failure: (any Error)?
      do {
        var index = 0
        for try await jpeg in scanner.scan(preset.scan, capabilities: capabilities) {
          let sheet = firstSheet + (duplex ? index / 2 : index)
          index += 1
          let page = try await Task.detached(priority: .userInitiated) {
            try PageImaging.page(from: jpeg, requestedDPI: dpi, sheet: sheet, blankThreshold: preset.blankThreshold)
          }.value
          add(page)
        }
      } catch {
        failure = error
      }
      finishScan(preset: preset, intoLast: intoLast, error: failure)
    }
  }

  func cancelScan() { scanTask?.cancel() }

  private func add(_ page: ScannedPage) {
    var page = page
    page.sequence = nextSequence
    nextSequence += 1
    pages[page.id] = page
    livePageIDs.append(page.id)
    phase = .scanning(pages: livePageIDs.count)
  }

  private func finishScan(preset: ScanPreset, intoLast: Bool, error: (any Error)?) {
    session.busyCount -= 1
    let ids = livePageIDs
    let metas = ids.compactMap { pages[$0] }.map { PageMeta(isBlank: $0.isBlank, sheet: $0.sheet) }
    if let lastSheet = metas.map(\.sheet).max() { nextSheet = lastSheet + 1 }

    let groups = BatchSplitter.split(metas, options: preset.split)
    let kept = Set(groups.joined())
    removedPageIDs += ids.indices.filter { !kept.contains($0) }.map { ids[$0] }
    var newDocuments = groups.map { ScanDocument(pageIDs: $0.map { ids[$0] }) }
    if intoLast, !newDocuments.isEmpty, !documents.isEmpty {
      documents[documents.count - 1].pageIDs += newDocuments.removeFirst().pageIDs
    }
    documents += newDocuments
    livePageIDs = []
    phase = .idle
    scanTask = nil

    if let error {
      let message = ErrorText.describe(error)
      session.log.append("Chyba: \(message)")
      let cancelled = (error as? TransportError) == .cancelled || error is CancellationError
      banner = Banner(
        kind: cancelled ? .info : .error,
        text: ids.isEmpty ? message : "\(message) Naskenované stránky (\(ids.count)) zůstaly v dávce.")
    } else if ids.isEmpty {
      banner = Banner(kind: .info, text: "Skener nevrátil žádnou stránku. Podrobnosti jsou v protokolu (⌘L).")
    }
  }

  // MARK: Manual fixes

  func mergeWithPrevious(_ documentID: UUID) {
    guard let index = documents.firstIndex(where: { $0.id == documentID }), index > 0 else { return }
    documents[index - 1].pageIDs += documents[index].pageIDs
    documents.remove(at: index)
  }

  func splitDocument(at pageID: UUID) {
    guard let index = documents.firstIndex(where: { $0.pageIDs.contains(pageID) }),
      let position = documents[index].pageIDs.firstIndex(of: pageID), position > 0
    else { return }
    let tail = Array(documents[index].pageIDs[position...])
    documents[index].pageIDs.removeSubrange(position...)
    documents.insert(ScanDocument(pageIDs: tail), at: index + 1)
  }

  func deletePage(_ pageID: UUID) {
    for index in documents.indices { documents[index].pageIDs.removeAll { $0 == pageID } }
    documents.removeAll { $0.pageIDs.isEmpty }
    removedPageIDs.removeAll { $0 == pageID }
    pages[pageID] = nil
  }

  func deleteDocument(_ documentID: UUID) {
    guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
    documents[index].pageIDs.forEach { pages[$0] = nil }
    documents.remove(at: index)
  }

  func rotate(_ pageID: UUID, by degrees: Int) {
    guard let rotation = pages[pageID]?.rotation else { return }
    pages[pageID]?.rotation = ((rotation + degrees) % 360 + 360) % 360
  }

  func rename(_ documentID: UUID, to name: String) {
    guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    documents[index].customName = trimmed.isEmpty || trimmed == plannedName(index: index) ? nil : trimmed
  }

  /// Puts a removed (blank) page back after the page that preceded it when scanning.
  func restore(_ pageID: UUID) {
    guard let sequence = pages[pageID]?.sequence else { return }
    removedPageIDs.removeAll { $0 == pageID }
    pages[pageID]?.isBlank = false
    var best: (document: Int, position: Int, sequence: Int)?
    for (documentIndex, document) in documents.enumerated() {
      for (position, id) in document.pageIDs.enumerated() {
        if let other = pages[id]?.sequence, sequence > other, other > (best?.sequence ?? -1) {
          best = (documentIndex, position, other)
        }
      }
    }
    if let best {
      documents[best.document].pageIDs.insert(pageID, at: best.position + 1)
    } else if documents.isEmpty {
      documents.append(ScanDocument(pageIDs: [pageID]))
    } else {
      documents[0].pageIDs.insert(pageID, at: 0)
    }
  }

  func clear() {
    pages = [:]
    documents = []
    removedPageIDs = []
    livePageIDs = []
    banner = nil
  }

  // MARK: Saving

  func save() {
    guard !isBusy, !documents.isEmpty else { return }
    let preset = self.preset
    let folder = preset.folderURL
    let namer = FileNamer(pattern: preset.namePattern)
    let ext = preset.output.fileExtension
    let exists: (String) -> Bool = { base in
      ["\(base).\(ext)", "\(base)-1.\(ext)"].contains {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
      }
    }

    // Counters continue after files already in the folder.
    var used = Set<String>()
    var counter = 1
    let jobs: [(name: String, pages: [ScanExporter.Page])] = documents.map { document in
      var name: String
      if let custom = document.customName {
        name = FileNamer.sanitize(custom)
      } else if namer.usesCounter {
        repeat {
          name = namer.name(index: counter)
          counter += 1
        } while used.contains(name) || exists(name)
      } else {
        name = namer.name(index: 1)
      }
      used.insert(name)
      let pages = document.pageIDs.compactMap { self.pages[$0] }.map {
        ScanExporter.Page(jpeg: $0.jpeg, rotation: $0.rotation, dpi: $0.dpi)
      }
      return (name, pages)
    }

    let format = preset.output
    let ocr = preset.ocr && format == .pdf
    banner = nil
    phase = .saving(done: 0, total: jobs.count)

    Task {
      var written: [URL] = []
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, job) in jobs.enumerated() {
          written += try await Task.detached(priority: .userInitiated) {
            try ScanExporter.export(job.pages, name: job.name, folder: folder, format: format, ocr: ocr)
          }.value
          phase = .saving(done: index + 1, total: jobs.count)
        }
        clear()
        phase = .idle
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        banner = Banner(
          kind: .success, text: "Uloženo \(plural(written.count, "soubor", "soubory", "souborů")) do \(path).",
          files: written)
        if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(written) }
      } catch {
        phase = .idle
        banner = Banner(kind: .error, text: "Uložení selhalo: \(ErrorText.describe(error))", files: written)
      }
    }
  }

  // MARK: Presets

  func duplicatePreset() {
    var copy = preset
    copy.id = UUID()
    copy.name += " – kopie"
    presets.append(copy)
    selectedPresetID = copy.id
  }

  func deletePreset() {
    guard presets.count > 1 else { return }
    presets.removeAll { $0.id == selectedPresetID }
    selectedPresetID = presets[0].id
  }

  func resetPresets() {
    presets = ScanPreset.defaults
    selectedPresetID = presets[0].id
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = preset.folderURL
    if panel.runModal() == .OK, let url = panel.url {
      preset.folder = (url.path as NSString).abbreviatingWithTildeInPath
    }
  }

  // MARK: Preview support

  /// Loads a finished sample batch (screenshots, previews).
  func loadSample() {
    session.busyCount += 1  // balanced by finishScan
    for index in 0..<5 {
      if let page = try? PageImaging.page(
        from: SampleDevice.pageJPEG(seed: index), requestedDPI: 150, sheet: index, blankThreshold: 0.0015)
      {
        add(page)
      }
    }
    if let blank = try? PageImaging.page(
      from: SampleDevice.pageJPEG(seed: 9, blank: true), requestedDPI: 150, sheet: 5, blankThreshold: 0.0015)
    {
      add(blank)
    }
    finishScan(preset: preset, intoLast: false, error: nil)
    let all = documents.flatMap(\.pageIDs)
    documents = [ScanDocument(pageIDs: Array(all.prefix(2))), ScanDocument(pageIDs: Array(all.dropFirst(2)))]
  }
}
