import PrinterKit
import SwiftUI

struct ScanView: View {
  @Bindable var model: ScanModel

  var body: some View {
    HSplitView {
      ScanSettingsForm(model: model)
        .frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
      BatchView(model: model)
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Předvolba", selection: $model.selectedPresetID) {
          ForEach(model.presets) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(model.isBusy)
      }
      ToolbarItem(placement: .primaryAction) {
        if model.isScanning {
          Button("Zastavit", systemImage: "stop.fill") { model.cancelScan() }
        } else {
          Button("Skenovat", systemImage: "doc.viewfinder") { model.scan() }
            .disabled(model.isBusy)
            .keyboardShortcut("r")
        }
      }
    }
    .sheet(item: previewBinding) { PagePreview(page: $0) }
  }

  private var previewBinding: Binding<ScannedPage?> {
    Binding(get: { model.previewPageID.flatMap { model.pages[$0] } }, set: { model.previewPageID = $0?.id })
  }
}

// MARK: - Settings

struct ScanSettingsForm: View {
  @Bindable var model: ScanModel
  @Environment(DeviceSession.self) private var session
  @State private var renaming = false
  @State private var newName = ""

  var body: some View {
    Form {
      Section("Skenování") {
        Picker("Zdroj", selection: $model.preset.scan.source) {
          ForEach(ScanSource.allCases) { Text($0.label).tag($0) }
        }
        if model.preset.scan.source == .feeder {
          Toggle("Oboustranně", isOn: $model.preset.scan.duplex)
            .disabled(session.scannerCapabilities?.hasDuplex == false)
          if let feeder = session.scannerStatus?.feeder {
            LabeledContent(
              "Podavač",
              value: feeder == .loaded ? "Papír vložen" : feeder == .empty ? "Prázdný" : ErrorText.feederProblem(feeder)
            )
          }
        } else if session.scannerStatus?.feeder == .loaded {
          Label("V podavači je papír – nechcete skenovat z podavače?", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        Picker("Barva", selection: $model.preset.scan.colorMode) {
          ForEach(ScanColorMode.allCases) { Text($0.label).tag($0) }
        }
        Picker("Rozlišení", selection: $model.preset.scan.resolution) {
          ForEach(model.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
        }
        Picker("Formát papíru", selection: $model.preset.scan.paper) {
          ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
        }
      }

      Section {
        Picker("Rozdělení", selection: $model.preset.split.mode) {
          ForEach(SplitMode.allCases) { Text($0.label).tag($0) }
        }
        if model.preset.split.mode == .everyN {
          Stepper("Po \(model.preset.split.everyN) stranách", value: $model.preset.split.everyN, in: 1...200)
        }
        Toggle("Vyřadit prázdné strany", isOn: $model.preset.split.removeBlankPages)
        LabeledContent {
          Slider(value: thresholdBinding, in: 0...1)
        } label: {
          Text("Citlivost")
          Text(
            "Prázdná = méně než \(model.preset.blankThreshold * 100, format: .number.precision(.fractionLength(2))) % plochy"
          )
        }
        Toggle("Rozpoznat text (OCR)", isOn: $model.preset.ocr)
          .disabled(model.preset.output == .jpeg)
      } header: {
        Text("Zpracování")
      } footer: {
        if model.preset.split.mode == .blankSeparator {
          Text("Mezi dokumenty vložte čistý list.").font(.caption).foregroundStyle(.secondary)
        }
      }

      Section {
        Picker("Výstup", selection: $model.preset.output) {
          ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
        }
        TextField("Název souboru", text: $model.preset.namePattern)
        LabeledContent("Složka") {
          HStack {
            Text(model.preset.folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button("Změnit…") { model.chooseFolder() }
          }
        }
        Toggle("Po uložení ukázat ve Finderu", isOn: $model.revealAfterSave)
      } header: {
        Text("Ukládání")
      } footer: {
        Text("Např. \(model.plannedName(index: 0)) · {datum} {čas} {č}").font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Menu("Předvolba „\(model.preset.name)“") {
          Button("Přejmenovat…") {
            newName = model.preset.name
            renaming = true
          }
          Button("Duplikovat") { model.duplicatePreset() }
          Button("Smazat", role: .destructive) { model.deletePreset() }.disabled(model.presets.count < 2)
          Divider()
          Button("Obnovit výchozí předvolby") { model.resetPresets() }
        }
        .fixedSize()
      }
    }
    .formStyle(.grouped)
    .disabled(model.isBusy)
    .alert("Přejmenovat předvolbu", isPresented: $renaming) {
      TextField("Název", text: $newName)
      Button("Uložit") { if !newName.isEmpty { model.preset.name = newName } }
      Button("Zrušit", role: .cancel) {}
    }
  }

  /// Logarithmic slider between 0.03 % and 1 %.
  private var thresholdBinding: Binding<Double> {
    let low = 0.0003
    let high = 0.01
    return Binding(
      get: { log(model.preset.blankThreshold / low) / log(high / low) },
      set: { model.preset.blankThreshold = low * pow(high / low, $0) })
  }
}

// MARK: - Batch

struct BatchView: View {
  var model: ScanModel
  @State private var confirmDiscard = false

  var body: some View {
    VStack(spacing: 0) {
      if let banner = model.banner {
        BannerView(banner: banner) { model.banner = nil }
      }
      content
      Divider()
      bottomBar
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .confirmationDialog("Zahodit celou dávku?", isPresented: $confirmDiscard) {
      Button("Zahodit", role: .destructive) { model.clear() }
    }
  }

  @ViewBuilder private var content: some View {
    if model.isScanning && model.livePageIDs.isEmpty {
      VStack(spacing: 12) {
        ProgressView().controlSize(.large)
        Text("Čekám na první stránku…").font(.title3.weight(.semibold))
        Text("Skener se zahřívá a podává papír.").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.isEmpty {
      ContentUnavailableView {
        Label("Zatím nic naskenováno", systemImage: "doc.viewfinder")
      } description: {
        Text(
          model.preset.scan.source == .feeder
            ? "Vložte papíry do podavače lícem nahoru a klikněte na Skenovat (⌘R)."
            : "Položte předlohu na sklo a klikněte na Skenovat (⌘R).")
      } actions: {
        Button("Skenovat") { model.scan() }.buttonStyle(.borderedProminent)
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          summary
          if !model.livePageIDs.isEmpty {
            Card(title: "Skenuji… \(model.livePageIDs.count). strana", systemImage: "scanner") {
              PageGrid(model: model, pageIDs: model.livePageIDs, editable: false)
            }
          }
          ForEach(Array(model.documents.enumerated()), id: \.element.id) { index, document in
            DocumentCard(model: model, document: document, index: index)
          }
          if !model.removedPageIDs.isEmpty { removedSection }
        }
        .padding(20)
      }
    }
  }

  private var summary: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(
        "\(plural(model.pageCount, "strana", "strany", "stran")) → \(plural(model.documents.count, "dokument", "dokumenty", "dokumentů"))"
      )
      .font(.title3.weight(.semibold))
      if !model.removedPageIDs.isEmpty {
        Text("vyřazeno \(plural(model.removedPageIDs.count, "prázdná strana", "prázdné strany", "prázdných stran"))")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var removedSection: some View {
    Card(title: "Vyřazené prázdné strany", systemImage: "eye.slash") {
      Text("Zkontrolujte, že mezi nimi není nic důležitého.").foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 116), spacing: 12)], alignment: .leading) {
        ForEach(model.removedPageIDs, id: \.self) { id in
          if let page = model.pages[id] {
            VStack {
              PageThumbnail(page: page).opacity(0.7)
              Button("Vrátit") { model.restore(id) }.controlSize(.small)
            }
          }
        }
      }
    }
  }

  private var bottomBar: some View {
    HStack(spacing: 10) {
      Label(model.preset.folder, systemImage: "folder").foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      if case .saving(let done, let total) = model.phase {
        ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 120)
      }
      Button("Zahodit") { confirmDiscard = true }
        .disabled(model.isBusy || model.isEmpty)
      Button("Přiskenovat do posledního") { model.scan(intoLast: true) }
        .disabled(model.isBusy || model.documents.isEmpty)
      Button(model.preset.output == .pdf ? "Uložit \(model.documents.count) PDF" : "Uložit obrázky") { model.save() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s")
        .disabled(model.isBusy || model.documents.isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

struct DocumentCard: View {
  var model: ScanModel
  var document: ScanDocument
  var index: Int

  var body: some View {
    Card {
      HStack(spacing: 8) {
        Image(systemName: model.preset.output == .pdf ? "doc.richtext" : "photo").foregroundStyle(.red)
        TextField(
          "Název",
          text: Binding(
            get: { document.customName ?? model.plannedName(index: index) },
            set: { model.rename(document.id, to: $0) })
        )
        .textFieldStyle(.plain)
        .font(.headline)
        Text(".\(model.preset.output.fileExtension)").foregroundStyle(.secondary)
        Spacer()
        Text(plural(document.pageIDs.count, "strana", "strany", "stran")).foregroundStyle(.secondary)
        if index > 0 {
          Button("Sloučit s předchozím") { model.mergeWithPrevious(document.id) }.controlSize(.small)
        }
        Button("Smazat dokument", systemImage: "trash") { model.deleteDocument(document.id) }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      PageGrid(model: model, pageIDs: document.pageIDs, editable: true)
    }
  }
}

struct PageGrid: View {
  var model: ScanModel
  var pageIDs: [UUID]
  var editable: Bool

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 116), spacing: 12)], alignment: .leading, spacing: 12)
    {
      ForEach(Array(pageIDs.enumerated()), id: \.element) { position, id in
        if let page = model.pages[id] {
          VStack(spacing: 4) {
            PageThumbnail(page: page)
            Text("\(position + 1)").font(.caption).foregroundStyle(.secondary)
          }
          .onTapGesture(count: 2) { model.previewPageID = id }
          .contextMenu {
            if editable {
              Button("Zobrazit") { model.previewPageID = id }
              Divider()
              Button("Otočit doprava") { model.rotate(id, by: 90) }
              Button("Otočit doleva") { model.rotate(id, by: -90) }
              Button("Otočit o 180°") { model.rotate(id, by: 180) }
              Divider()
              Button("Začít zde nový dokument") { model.splitDocument(at: id) }.disabled(position == 0)
              Button("Smazat stránku", role: .destructive) { model.deletePage(id) }
            }
          }
        }
      }
    }
  }
}

struct PageThumbnail: View {
  var page: ScannedPage

  var body: some View {
    let sideways = page.rotation == 90 || page.rotation == 270
    Image(decorative: page.thumbnail.image, scale: 1)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: sideways ? 132 : 96, height: sideways ? 96 : 132)
      .rotationEffect(.degrees(Double(page.rotation)))
      .frame(width: 96, height: 132)
      .background(.white)
      .clipShape(.rect(cornerRadius: 2))
      .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
  }
}

struct PagePreview: View {
  var page: ScannedPage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      if let image = NSImage(data: page.jpeg) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .rotationEffect(.degrees(Double(page.rotation)))
          .frame(minWidth: 500, idealWidth: 640, minHeight: 600, idealHeight: 820)
      }
      HStack {
        Text("Obsah: \(page.inkRatio * 100, format: .number.precision(.fractionLength(2))) % plochy · \(page.dpi) dpi")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Zavřít") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
  }
}
