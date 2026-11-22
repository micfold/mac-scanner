import SwiftUI
import AppKit
import ScanCore

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner)
            }
            if model.isScanning && model.livePageIDs.isEmpty && model.documents.isEmpty {
                waitingState
            } else if model.documents.isEmpty && model.livePageIDs.isEmpty && model.removedPageIDs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        summary
                        if !model.livePageIDs.isEmpty { liveSection }
                        ForEach(Array(model.documents.enumerated()), id: \.element.id) { index, doc in
                            DocumentCard(doc: doc, index: index)
                        }
                        if !model.removedPageIDs.isEmpty { removedSection }
                    }
                    .padding(20)
                }
            }
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .confirmationDialog("Zahodit celou dávku?", isPresented: $confirmDiscard) {
            Button("Zahodit", role: .destructive) { model.clearBatch() }
        } message: {
            Text("Naskenované stránky, které jste neuložili, se ztratí.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Zatím nic naskenováno", systemImage: "doc.viewfinder")
        } description: {
            Text(model.preset.scan.source == .feeder
                 ? "Vložte papíry do podavače lícem nahoru a klikněte na Skenovat (⌘R)."
                 : "Položte předlohu na sklo a klikněte na Skenovat (⌘R).")
        } actions: {
            Button("Skenovat") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waitingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Čekám na první stránku…").font(.title3.weight(.semibold))
            Text("Skener se zahřívá a podává papír. Může to trvat několik sekund.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Zastavit") { model.cancelScan() }
                Button("Protokol komunikace") { model.showLog = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: some View {
        let removed = model.removedPageIDs.count
        let pagesText = "\(model.batchPageCount) " + plural(model.batchPageCount, "strana", "strany", "stran")
        let docsText = "\(model.documents.count) " + plural(model.documents.count, "dokument", "dokumenty", "dokumentů")
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(pagesText) → \(docsText)").font(.title3.weight(.semibold))
            if removed > 0 {
                Text("vyřazeno \(removed) " + plural(removed, "prázdná strana", "prázdné strany", "prázdných stran"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Skenuji… \(model.livePageIDs.count). strana").font(.headline)
            }
            PageGrid(pageIDs: model.livePageIDs, interactive: false)
        }
        .cardStyle()
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vyřazené prázdné strany").font(.headline)
            Text("Zkontrolujte, že mezi nimi není nic důležitého – stránku vrátíte tlačítkem pod náhledem.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 116), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(model.removedPageIDs, id: \.self) { pid in
                    if let p = model.pages[pid] {
                        VStack(spacing: 4) {
                            PageThumb(page: p).opacity(0.75)
                                .onTapGesture(count: 2) { model.previewPageID = pid }
                            Button("Vrátit") { model.restore(pid) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                model.showLog = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Protokol komunikace se skenerem (⌘L)")
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.preset.folder)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            if case let .saving(done, total) = model.phase {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text(model.preset.ocr && model.preset.output == .pdf
                     ? "Rozpoznávám text a ukládám \(done)/\(total)…"
                     : "Ukládám \(done)/\(total)…")
                    .foregroundStyle(.secondary)
            }
            Button("Zahodit") { confirmDiscard = true }
                .disabled(model.isBusy || model.documents.isEmpty && model.removedPageIDs.isEmpty)
            Button("Přiskenovat do posledního") { model.startScan(intoLast: true) }
                .disabled(model.isBusy || model.documents.isEmpty)
                .help("Další stránky se připojí k poslednímu dokumentu (⇧⌘R)")
            Button(saveTitle) { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.documents.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var saveTitle: String {
        let n = model.documents.count
        guard n > 0 else { return "Uložit" }
        if model.preset.output == .jpeg { return "Uložit obrázky" }
        return "Uložit \(n) PDF"
    }
}

// MARK: - Dokument

struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let doc: ScanDocument
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: model.preset.output == .pdf ? "doc.richtext" : "photo.on.rectangle")
                    .foregroundStyle(.red)
                TextField("Název", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.headline)
                Text(model.preset.output == .pdf ? ".pdf" : ".jpg").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(doc.pageIDs.count) " + plural(doc.pageIDs.count, "strana", "strany", "stran"))
                    .foregroundStyle(.secondary)
                if index > 0 {
                    Button("Sloučit s předchozím") { model.mergeWithPrevious(doc.id) }
                        .controlSize(.small)
                }
                Button {
                    model.deleteDocument(doc.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Smazat celý dokument")
            }
            PageGrid(pageIDs: doc.pageIDs, interactive: true)
        }
        .cardStyle()
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { doc.customName ?? model.plannedName(index: index) },
            set: { model.rename(doc.id, to: $0) }
        )
    }
}

struct PageGrid: View {
    @Environment(AppModel.self) private var model
    let pageIDs: [UUID]
    let interactive: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 116), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            ForEach(Array(pageIDs.enumerated()), id: \.element) { k, pid in
                if let p = model.pages[pid] {
                    VStack(spacing: 4) {
                        PageThumb(page: p)
                        Text("\(k + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    .onTapGesture(count: 2) { model.previewPageID = pid }
                    .contextMenu {
                        if interactive {
                            Button("Zobrazit") { model.previewPageID = pid }
                            Divider()
                            Button("Otočit doprava") { model.rotate(pid, by: 90) }
                            Button("Otočit doleva") { model.rotate(pid, by: -90) }
                            Button("Otočit o 180°") { model.rotate(pid, by: 180) }
                            Divider()
                            Button("Začít zde nový dokument") { model.splitDocument(at: pid) }
                                .disabled(k == 0)
                            Button("Smazat stránku", role: .destructive) { model.deletePage(pid) }
                        }
                    }
                }
            }
        }
    }
}

struct PageThumb: View {
    let page: ScannedPage

    var body: some View {
        let sideways = page.rotation == 90 || page.rotation == 270
        Image(decorative: page.thumbnail, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: sideways ? 132 : 96, height: sideways ? 96 : 132)
            .rotationEffect(.degrees(Double(page.rotation)))
            .frame(width: 96, height: 132)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .help("Dvojklikem zvětšíte")
    }
}

// MARK: - Pomocné

struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(banner.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !banner.reveal.isEmpty {
                Button("Ukázat ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting(banner.reveal) }
            }
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Zavřít")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.12))
    }

    private var icon: String {
        switch banner.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: .blue
        case .success: .green
        case .error: .orange
        }
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Česká množná čísla: 1 strana, 2–4 strany, 5+ stran.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if n == 1 { return one }
    if (2...4).contains(n) { return few }
    return many
}
