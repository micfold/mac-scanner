import SwiftUI
import AppKit
import Observation
import ScanCore

struct ScanDocument: Identifiable, Equatable {
    let id = UUID()
    var pageIDs: [UUID]
    var customName: String?
}

struct Banner: Equatable {
    enum Kind { case info, success, error }
    var kind: Kind
    var text: String
    var reveal: [URL] = []
}

enum Phase: Equatable {
    case idle
    case scanning(pages: Int)
    case saving(done: Int, total: Int)
}

enum ConnectionState: Equatable {
    case unknown, connecting, connected, failed(String)
}

@Observable @MainActor
final class AppModel {
    private enum Keys {
        static let presets = "presets.v1"
        static let selected = "selectedPreset"
        static let endpoint = "endpoint.v1"
        static let revealAfterSave = "revealAfterSave"
    }

    // MARK: Nastavení

    var presets: [Preset] { didSet { persistPresets() } }
    var selectedPresetID: UUID {
        didSet { UserDefaults.standard.set(selectedPresetID.uuidString, forKey: Keys.selected) }
    }
    var endpoint: ESCLEndpoint {
        didSet {
            persistEndpoint()
            capabilities = nil
            status = nil
            connection = .unknown
            Task { await refresh() }
        }
    }
    var hostText: String
    var revealAfterSave: Bool {
        didSet { UserDefaults.standard.set(revealAfterSave, forKey: Keys.revealAfterSave) }
    }

    /// Aktuální předvolba – úpravy v panelu nastavení se do ní rovnou ukládají.
    var preset: Preset {
        get { presets.first { $0.id == selectedPresetID } ?? presets[0] }
        set {
            if let i = presets.firstIndex(where: { $0.id == newValue.id }) { presets[i] = newValue }
        }
    }

    // MARK: Skener

    var connection: ConnectionState = .unknown
    var capabilities: ScannerCapabilities?
    var status: ScannerStatus?
    let discovery: ScannerDiscovery

    // MARK: Dávka

    var pages: [UUID: ScannedPage] = [:]
    var documents: [ScanDocument] = []
    var removedPageIDs: [UUID] = []
    var livePageIDs: [UUID] = []
    var phase: Phase = .idle
    var banner: Banner?
    var previewPageID: UUID?

    // MARK: Protokol komunikace
    var logLines: [String] = []
    var showLog = false
    @ObservationIgnored private var logFile: FileHandle?

    private static func openLogFile() -> FileHandle? {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Skener.log")
    }

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var nextSheet = 0
    @ObservationIgnored private var nextSeq = 0

    init() {
        discovery = ScannerDiscovery()
        logFile = Self.openLogFile()
        let d = UserDefaults.standard
        var loaded = Preset.defaults
        if let data = d.data(forKey: Keys.presets),
           let p = try? JSONDecoder().decode([Preset].self, from: data), !p.isEmpty {
            loaded = p
        }
        presets = loaded
        if let s = d.string(forKey: Keys.selected), let id = UUID(uuidString: s), loaded.contains(where: { $0.id == id }) {
            selectedPresetID = id
        } else {
            selectedPresetID = loaded[0].id
        }
        var ep = ESCLEndpoint(host: "")
        if let data = d.data(forKey: Keys.endpoint), let e = try? JSONDecoder().decode(ESCLEndpoint.self, from: data) {
            ep = e
        }
        endpoint = ep
        hostText = ep.port.map { "\(ep.host):\($0)" } ?? ep.host
        revealAfterSave = d.object(forKey: Keys.revealAfterSave) as? Bool ?? true
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: Keys.presets) }
    }

    private func persistEndpoint() {
        if let data = try? JSONEncoder().encode(endpoint) { UserDefaults.standard.set(data, forKey: Keys.endpoint) }
    }

    // MARK: Odvozené hodnoty

    var isBusy: Bool { phase != .idle }
    var isScanning: Bool { if case .scanning = phase { return true } else { return false } }
    var batchPageCount: Int { documents.reduce(0) { $0 + $1.pageIDs.count } }

    var currentInputCaps: InputCaps? {
        capabilities?.caps(for: preset.scan.source, duplex: preset.scan.effectiveDuplex)
    }

    var availableResolutions: [Int] {
        var r = currentInputCaps?.resolutions.filter { $0 >= 100 && $0 <= 600 } ?? []
        if r.isEmpty { r = [150, 200, 300, 600] }
        if !r.contains(preset.scan.resolution) { r.append(preset.scan.resolution) }
        return r.sorted()
    }

    /// Rozlišení, které skener opravdu použije (nejbližší podporované).
    var effectiveResolution: Int {
        let want = preset.scan.resolution
        guard let r = currentInputCaps?.resolutions, !r.isEmpty, !r.contains(want) else { return want }
        return r.min(by: { abs($0 - want) < abs($1 - want) }) ?? want
    }

    var connectionSubtitle: String {
        switch connection {
        case .connected: return "\(capabilities?.makeAndModel ?? "Skener") · \(endpoint.host)"
        case .connecting: return "Připojuji se k \(endpoint.host)…"
        case .failed: return "Skener \(endpoint.host) nedostupný"
        case .unknown: return endpoint.host
        }
    }

    var feederStateText: String? {
        guard let st = status else { return nil }
        if let p = st.adfProblem { return p }
        switch st.adfLoaded {
        case true?: return "Papír vložen"
        case false?: return "Prázdný"
        case nil: return nil
        }
    }

    func plannedName(index: Int) -> String {
        FileNamer(pattern: preset.namePattern).name(index: index + 1)
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Protokol

    func appendLog(_ line: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let stamped = "\(df.string(from: Date()))  \(line)"
        logLines.append(stamped)
        if logLines.count > 3000 { logLines.removeFirst(logLines.count - 3000) }
        logFile?.write(Data((stamped + "\n").utf8))
    }

    /// Klient, jehož komunikace se zapisuje do protokolu.
    private func loggingClient(_ ep: ESCLEndpoint) -> ESCLClient {
        let c = ESCLClient(endpoint: ep)
        c.log = { [weak self] line in
            Task { @MainActor [weak self] in self?.appendLog(line) }
        }
        return c
    }

    private func snapResolutions() {
        guard let caps = capabilities else { return }
        for i in presets.indices {
            let want = presets[i].scan.resolution
            guard let r = caps.caps(for: presets[i].scan.source, duplex: presets[i].scan.effectiveDuplex)?.resolutions,
                  !r.isEmpty, !r.contains(want),
                  let best = r.min(by: { abs($0 - want) < abs($1 - want) }) else { continue }
            presets[i].scan.resolution = best
        }
    }

    // MARK: Spojení

    func applyHostText() {
        let t = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var host = t, port: Int?
        if let colon = t.lastIndex(of: ":"), let p = Int(t[t.index(after: colon)...]), !t.contains("]") {
            host = String(t[..<colon]); port = p
        }
        let ep = ESCLEndpoint(host: host, port: port, rootPath: endpoint.rootPath)
        if ep != endpoint { endpoint = ep } else { Task { await refresh(force: true) } }
    }

    func use(_ found: ScannerDiscovery.Found) {
        hostText = found.port == 80 ? found.host : "\(found.host):\(found.port)"
        endpoint = ESCLEndpoint(host: found.host, port: found.port == 80 ? nil : found.port, rootPath: found.rootPath)
    }

    /// Běží po celou dobu, co je okno otevřené: drží spojení a stav podavače aktuální.
    func monitor() async {
        while !Task.isCancelled {
            if !isBusy { await refresh() }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    func refresh(force: Bool = false) async {
        let ep = endpoint
        guard !ep.host.isEmpty else {
            connection = .failed("Zadejte IP adresu skeneru nebo ho vyberte ze seznamu nalezených.")
            return
        }
        let client = force ? loggingClient(ep) : ESCLClient(endpoint: ep)
        if capabilities == nil || force {
            if connection == .unknown || force { connection = .connecting }
            do {
                let caps = try await client.capabilities()
                guard ep == endpoint else { return }
                capabilities = caps
                connection = .connected
                snapResolutions()
            } catch {
                guard ep == endpoint else { return }
                connection = .failed(Self.message(error))
                status = nil
                return
            }
        }
        if let st = try? await client.status(), ep == endpoint { status = st }
    }

    // MARK: Skenování

    /// Naskenuje dávku. Nové dokumenty se přidají na konec;
    /// s `intoLast` se první dokument z nového skenu připojí k poslednímu existujícímu.
    func startScan(intoLast: Bool = false) {
        guard !isBusy else { return }
        guard !endpoint.host.isEmpty else {
            banner = Banner(kind: .error, text: "Nejdřív zadejte IP adresu skeneru (vlevo nahoře).")
            return
        }
        banner = nil
        appendLog("=== Skenování: předvolba „\(preset.name)“, \(preset.scan.source.label)\(preset.scan.effectiveDuplex ? " oboustranně" : ""), \(effectiveResolution) dpi ===")
        let preset = self.preset
        let ep = endpoint
        let knownCaps = capabilities
        let dpi = effectiveResolution
        let duplex = preset.scan.effectiveDuplex
        let sheetBase = nextSheet
        livePageIDs = []
        phase = .scanning(pages: 0)

        let client = loggingClient(ep)
        scanTask = Task { [self] in
            var failure: Error?
            do {
                var caps = knownCaps
                if caps == nil {
                    caps = try await client.capabilities()
                    self.capabilities = caps
                    self.connection = .connected
                }
                try await client.scan(settings: preset.scan, capabilities: caps) { [self] data, index in
                    let sheet = sheetBase + (duplex ? index / 2 : index)
                    do {
                        let page = try await Task.detached(priority: .userInitiated) {
                            try PageProcessor.make(jpeg: data, requestedDPI: dpi, sheet: sheet,
                                                   threshold: preset.blankThreshold)
                        }.value
                        await self.received(page)
                    } catch {
                        await self.showError(error)
                    }
                }
            } catch {
                failure = error
            }
            self.finishScan(preset: preset, intoLast: intoLast, error: failure)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func received(_ page: ScannedPage) {
        var p = page
        p.seq = nextSeq
        nextSeq += 1
        pages[p.id] = p
        livePageIDs.append(p.id)
        phase = .scanning(pages: livePageIDs.count)
    }

    private func showError(_ error: Error) {
        banner = Banner(kind: .error, text: Self.message(error))
    }

    private func finishScan(preset: Preset, intoLast: Bool, error: Error?) {
        let ids = livePageIDs
        let metas = ids.map { PageMeta(isBlank: pages[$0]?.isBlank ?? false, sheet: pages[$0]?.sheet ?? 0) }
        if let maxSheet = metas.map(\.sheet).max() { nextSheet = maxSheet + 1 }

        let groups = DocumentSplitter.split(metas, options: preset.split)
        let kept = Set(groups.flatMap { $0 })
        removedPageIDs += ids.indices.filter { !kept.contains($0) }.map { ids[$0] }

        var newDocs = groups.map { ScanDocument(pageIDs: $0.map { ids[$0] }) }
        if intoLast, !newDocs.isEmpty, !documents.isEmpty {
            documents[documents.count - 1].pageIDs += newDocs.removeFirst().pageIDs
        }
        documents += newDocs
        livePageIDs = []
        phase = .idle
        scanTask = nil

        if let error {
            let cancelled = (error as? ESCLError) == .cancelled
            let msg = Self.message(error)
            let text = ids.isEmpty ? msg : "\(msg) Naskenované stránky (\(ids.count)) zůstaly v dávce."
            appendLog("Chyba: \(msg)")
            banner = Banner(kind: cancelled ? .info : .error, text: text)
        } else if ids.isEmpty {
            banner = Banner(kind: .info, text: "Skener nevrátil žádnou stránku. Podrobnosti jsou v protokolu komunikace (⌘L).")
        }
        Task { await refresh() }
    }

    // MARK: Ruční úpravy dávky

    func mergeWithPrevious(_ docID: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == docID }), i > 0 else { return }
        documents[i - 1].pageIDs += documents[i].pageIDs
        documents.remove(at: i)
    }

    func splitDocument(at pageID: UUID) {
        guard let i = documents.firstIndex(where: { $0.pageIDs.contains(pageID) }),
              let k = documents[i].pageIDs.firstIndex(of: pageID), k > 0 else { return }
        let tail = Array(documents[i].pageIDs[k...])
        documents[i].pageIDs.removeSubrange(k...)
        documents.insert(ScanDocument(pageIDs: tail), at: i + 1)
    }

    func deletePage(_ pageID: UUID) {
        for i in documents.indices { documents[i].pageIDs.removeAll { $0 == pageID } }
        documents.removeAll { $0.pageIDs.isEmpty }
        removedPageIDs.removeAll { $0 == pageID }
        pages[pageID] = nil
    }

    func deleteDocument(_ docID: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == docID }) else { return }
        for p in documents[i].pageIDs { pages[p] = nil }
        documents.remove(at: i)
    }

    func rotate(_ pageID: UUID, by degrees: Int) {
        guard let r = pages[pageID]?.rotation else { return }
        pages[pageID]?.rotation = ((r + degrees) % 360 + 360) % 360
    }

    func rename(_ docID: UUID, to name: String) {
        guard let i = documents.firstIndex(where: { $0.id == docID }) else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[i].customName = (t.isEmpty || t == plannedName(index: i)) ? nil : t
    }

    /// Vrátí vyřazenou (prázdnou) stránku za stránku, která ji při skenování předcházela.
    func restore(_ pageID: UUID) {
        guard let seq = pages[pageID]?.seq else { return }
        removedPageIDs.removeAll { $0 == pageID }
        pages[pageID]?.isBlank = false
        var best: (doc: Int, pos: Int, seq: Int)?
        for (di, d) in documents.enumerated() {
            for (pi, p) in d.pageIDs.enumerated() {
                if let s = pages[p]?.seq, seq > s, s > (best?.seq ?? -1) { best = (di, pi, s) }
            }
        }
        if let best {
            documents[best.doc].pageIDs.insert(pageID, at: best.pos + 1)
        } else if !documents.isEmpty {
            documents[0].pageIDs.insert(pageID, at: 0)
        } else {
            documents.append(ScanDocument(pageIDs: [pageID]))
        }
    }

    func clearBatch() {
        pages = [:]
        documents = []
        removedPageIDs = []
        livePageIDs = []
        banner = nil
    }

    // MARK: Ukládání

    func save() {
        guard !isBusy, !documents.isEmpty else { return }
        let preset = self.preset
        let folder = preset.folderURL
        let ext = preset.output == .pdf ? "pdf" : "jpg"
        let namer = FileNamer(pattern: preset.namePattern)
        let usesIndex = ["{č}", "{c}", "{n}"].contains { preset.namePattern.contains($0) }
        let fm = FileManager.default
        func taken(_ base: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent("\(base).\(ext)").path) ||
            fm.fileExists(atPath: folder.appendingPathComponent("\(base)-1.\(ext)").path)
        }

        // Pořadová čísla navazují na soubory, které už ve složce jsou.
        var used = Set<String>()
        var n = 1
        var jobs: [(name: String, pages: [Exporter.PageInput])] = []
        for doc in documents {
            var base = ""
            if let custom = doc.customName {
                base = FileNamer.sanitize(custom)
            } else if usesIndex {
                repeat { base = namer.name(index: n); n += 1 } while used.contains(base) || taken(base)
            } else {
                base = namer.name(index: 1)
            }
            used.insert(base)
            let inputs = doc.pageIDs.compactMap { pages[$0] }.map {
                Exporter.PageInput(jpeg: $0.jpeg, rotation: $0.rotation, dpi: $0.dpi)
            }
            jobs.append((base, inputs))
        }

        let ocr = preset.ocr && preset.output == .pdf
        let output = preset.output
        banner = nil
        phase = .saving(done: 0, total: jobs.count)

        Task { [self] in
            var written: [URL] = []
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (k, job) in jobs.enumerated() {
                    let urls = try await Task.detached(priority: .userInitiated) {
                        try Exporter.export(job.pages, baseName: job.name, folder: folder, format: output, ocr: ocr)
                    }.value
                    written += urls
                    self.phase = .saving(done: k + 1, total: jobs.count)
                }
                self.didSave(written, folder: folder)
            } catch {
                self.phase = .idle
                let extra = written.isEmpty ? "" : " Před chybou se uložilo \(written.count) souborů."
                self.banner = Banner(kind: .error, text: "Uložení selhalo: \(AppModel.message(error))\(extra)", reveal: written)
            }
        }
    }

    private func didSave(_ urls: [URL], folder: URL) {
        clearBatch()
        phase = .idle
        let word = urls.count == 1 ? "soubor" : (urls.count < 5 ? "soubory" : "souborů")
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        banner = Banner(kind: .success, text: "Uloženo \(urls.count) \(word) do \(path).", reveal: urls)
        if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: Předvolby

    func duplicatePreset() {
        var p = preset
        p.id = UUID()
        p.name = "\(preset.name) – kopie"
        presets.append(p)
        selectedPresetID = p.id
    }

    func deletePreset() {
        guard presets.count > 1 else { return }
        presets.removeAll { $0.id == selectedPresetID }
        selectedPresetID = presets[0].id
    }

    func resetPresets() {
        presets = Preset.defaults
        selectedPresetID = presets[0].id
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Vybrat"
        panel.directoryURL = preset.folderURL
        if panel.runModal() == .OK, let url = panel.url {
            preset.folder = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
