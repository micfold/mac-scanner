import PrinterKit
import SwiftUI
import UniformTypeIdentifiers

struct PrintView: View {
  @Bindable var model: PrintModel
  @State private var isDropTargeted = false

  var body: some View {
    VStack(spacing: 0) {
      if let banner = model.banner {
        BannerView(banner: banner) { model.banner = nil }
      }
      HSplitView {
        documentList
          .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
        preview
          .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        PrintOptionsForm(model: model)
          .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Tisknout", systemImage: "printer") { model.print() }
          .disabled(!model.canPrint)
          .keyboardShortcut("p")
      }
    }
  }

  private var documentList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Soubory k tisku")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 14)
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(model.documents) { document in
            DocumentRow(document: document, isSelected: document.id == model.selected?.id)
              .onTapGesture { model.selectedID = document.id }
              .contextMenu { Button("Odebrat", role: .destructive) { model.remove(document.id) } }
          }
        }
        .padding(8)
      }
      DropZone(title: "Přetáhněte PDF nebo obrázky", systemImage: "arrow.down.doc", isTargeted: isDropTargeted)
        .padding(12)
        .onTapGesture { model.chooseFiles() }
    }
    .dropDestination(for: URL.self) { urls, _ in
      model.add(urls)
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
  }

  @ViewBuilder private var preview: some View {
    if let pdf = model.previewPDF {
      VStack(spacing: 0) {
        PDFPagesView(data: pdf)
        HStack {
          if let sheets = model.sheetsEstimate {
            Label("≈ \(plural(sheets, "list", "listy", "listů")) papíru", systemImage: "doc.plaintext")
          }
          Spacer()
          Text(model.routeDescription)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.bar)
      }
    } else {
      ContentUnavailableView {
        Label("Nic k tisku", systemImage: "printer")
      } description: {
        Text("Přetáhněte sem PDF nebo obrázky, nebo je otevřete.")
      } actions: {
        Button("Otevřít soubory…") { model.chooseFiles() }.buttonStyle(.borderedProminent)
      }
      .dropDestination(for: URL.self) { urls, _ in
        model.add(urls)
        return true
      }
    }
  }
}

private struct DocumentRow: View {
  var document: PrintDocument
  var isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "doc.richtext").foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text(document.name).lineLimit(1)
        Text(plural(document.pageCount, "strana", "strany", "stran")).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 7))
    .contentShape(.rect)
  }
}

struct PrintOptionsForm: View {
  @Bindable var model: PrintModel
  @State private var newPresetName = ""
  @State private var namingPreset = false

  var body: some View {
    Form {
      Section("Předvolba") {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
          ForEach(model.presets) { preset in
            let active = model.isActive(preset)
            Button {
              model.apply(preset)
            } label: {
              VStack(spacing: 4) {
                Image(systemName: preset.symbol).font(.title3)
                Text(preset.name).font(.caption).lineLimit(1)
              }
              .frame(maxWidth: .infinity, minHeight: 52)
              .foregroundStyle(active ? Color.accentColor : .primary)
              .background(
                active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
          }
        }
        Button("Uložit nastavení jako předvolbu…") { namingPreset = true }
          .buttonStyle(.link)
      }

      Section("Kopie a stránky") {
        Stepper("Kopie: \(model.ticket.copies)", value: $model.ticket.copies, in: 1...model.maxCopies)
        TextField("Stránky", text: $model.pageRangeText, prompt: Text("Všechny, např. 1-3, 5"))
          .foregroundStyle(model.pageRangeIsValid ? Color.primary : Color.red)
        Picker("Stránek na list", selection: $model.ticket.numberUp) {
          ForEach(model.numberUpOptions, id: \.self) { Text("\($0)").tag($0) }
        }
      }

      Section("Papír") {
        Picker("Formát", selection: $model.ticket.media) {
          Text("Výchozí").tag(String?.none)
          ForEach(model.mediaOptions, id: \.self) { Text(MediaText.name($0)).tag(String?.some($0)) }
        }
        if !model.sourceOptions.isEmpty {
          Picker("Zásobník", selection: $model.ticket.mediaSource) {
            Text("Automaticky").tag(String?.none)
            ForEach(model.sourceOptions, id: \.self) { Text(MediaText.source($0)).tag(String?.some($0)) }
          }
        }
        Picker("Orientace", selection: $model.ticket.orientation) {
          Text("Automaticky").tag(Orientation?.none)
          ForEach(Orientation.allCases) { Text($0.label).tag(Orientation?.some($0)) }
        }
        Picker("Velikost", selection: $model.ticket.scaling) {
          ForEach(model.scalingOptions) { Text($0.label).tag($0) }
        }
      }

      Section("Tisk") {
        Picker("Strany", selection: $model.ticket.sides) {
          ForEach(model.sidesOptions) { Text($0.label).tag($0) }
        }
        Picker("Barva", selection: $model.ticket.colorMode) {
          ForEach(model.colorOptions) { Text($0.label).tag($0) }
        }
        Picker("Kvalita", selection: $model.ticket.quality) {
          ForEach(model.qualityOptions) { Text($0.label).tag($0) }
        }
      }

      Section {
        if let letterhead = model.letterhead {
          LabeledContent("Podklad") {
            HStack {
              Text(letterhead.name).lineLimit(1)
              Button("Odebrat", systemImage: "xmark.circle.fill") { model.removeLetterhead() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
          }
        } else {
          Button("Vybrat hlavičkový papír (PDF)…") { model.chooseLetterhead() }
        }
      } header: {
        Text("Hlavičkový papír")
      } footer: {
        Text("Každá stránka se vytiskne přes první stranu zvoleného PDF – logo, adresa, patička.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button(model.documents.count > 1 ? "Tisknout vybraný" : "Tisknout") { model.print() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canPrint)
        if model.documents.count > 1 {
          Button("Tisknout všechny (\(model.documents.count))") { model.print(all: true) }
            .disabled(!model.canPrint)
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isPrinting)
    .alert("Nová předvolba", isPresented: $namingPreset) {
      TextField("Název", text: $newPresetName)
      Button("Uložit") { if !newPresetName.isEmpty { model.saveAsPreset(named: newPresetName) } }
      Button("Zrušit", role: .cancel) {}
    }
  }
}

/// Renders the PDF exactly as it will print, page by page.
struct PDFPagesView: View {
  var data: Data
  @State private var pages: [Thumbnail] = []

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 18) {
        ForEach(pages.indices, id: \.self) { index in
          Image(decorative: pages[index].image, scale: 2)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 520)
            .background(.white)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .task(id: data) {
      let data = self.data
      pages = await Task.detached(priority: .userInitiated) { PrintComposer.render(data, width: 1040) }.value
    }
  }
}
