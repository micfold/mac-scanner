import SwiftUI
import ScanCore

struct SettingsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Skener") {
                HStack {
                    TextField("Adresa", text: $model.hostText, prompt: Text("IP adresa tiskárny"))
                        .onSubmit { model.applyHostText() }
                    Menu {
                        if model.discovery.found.isEmpty {
                            Text("Hledám skenery v síti…")
                        }
                        ForEach(model.discovery.found) { f in
                            Button("\(f.name) (\(f.host))") { model.use(f) }
                        }
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Skenery nalezené v síti")
                }
                LabeledContent("Stav") { ConnectionBadge() }
                if model.preset.scan.source == .feeder, let adf = model.feederStateText {
                    LabeledContent("Podavač", value: adf)
                }
            }

            Section("Skenování") {
                Picker("Zdroj", selection: $model.preset.scan.source) {
                    ForEach(InputSource.allCases) { Text($0.label).tag($0) }
                }
                if model.preset.scan.source == .feeder {
                    Toggle("Oboustranně", isOn: $model.preset.scan.duplex)
                        .disabled(model.capabilities?.hasDuplex == false)
                } else if model.status?.adfLoaded == true {
                    Label("V podavači je papír. Pro skenování z podavače přepněte Zdroj na Podavač.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Picker("Barva", selection: $model.preset.scan.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Rozlišení", selection: $model.preset.scan.resolution) {
                    ForEach(model.availableResolutions, id: \.self) { Text("\($0) dpi").tag($0) }
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
                    Stepper("Po \(model.preset.split.everyN) stranách",
                            value: $model.preset.split.everyN, in: 1...200)
                }
                Toggle("Vyřadit prázdné strany", isOn: $model.preset.split.removeBlankPages)
                LabeledContent {
                    Slider(value: thresholdBinding, in: 0...1)
                } label: {
                    Text("Citlivost")
                    Text("Prázdná = méně než \(String(format: "%.2f", model.preset.blankThreshold * 100)) % plochy")
                }
                Toggle("Rozpoznat text (OCR)", isOn: $model.preset.ocr)
                    .disabled(model.preset.output == .jpeg)
            } header: {
                Text("Zpracování")
            } footer: {
                if model.preset.split.mode == .blankSeparator {
                    Text(model.preset.scan.effectiveDuplex
                         ? "Mezi dokumenty vložte čistý list. Prázdný rub jednostranné stránky dokument nerozdělí."
                         : "Mezi dokumenty vložte čistý list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Výstup", selection: $model.preset.output) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                TextField("Název souboru", text: $model.preset.namePattern)
                LabeledContent("Složka") {
                    HStack(spacing: 6) {
                        Text(model.preset.folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Změnit…") { model.chooseFolder() }
                    }
                }
                Toggle("Po uložení ukázat ve Finderu", isOn: $model.revealAfterSave)
            } header: {
                Text("Ukládání")
            } footer: {
                Text("Např. \(model.plannedName(index: 0)) · zástupné znaky {datum} {čas} {č}")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Menu("Předvolba „\(model.preset.name)“") {
                        Button("Přejmenovat…") {
                            newName = model.preset.name
                            renaming = true
                        }
                        Button("Duplikovat") { model.duplicatePreset() }
                        Button("Smazat", role: .destructive) { model.deletePreset() }
                            .disabled(model.presets.count < 2)
                        Divider()
                        Button("Obnovit výchozí předvolby…") { confirmDelete = true }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        .alert("Přejmenovat předvolbu", isPresented: $renaming) {
            TextField("Název", text: $newName)
            Button("Uložit") {
                let t = newName.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { model.preset.name = t }
            }
            Button("Zrušit", role: .cancel) {}
        }
        .confirmationDialog("Obnovit výchozí předvolby?", isPresented: $confirmDelete) {
            Button("Obnovit", role: .destructive) { model.resetPresets() }
        } message: {
            Text("Vaše úpravy předvoleb se ztratí.")
        }
    }

    /// Posuvník v logaritmickém měřítku 0,03 % – 1 %.
    private var thresholdBinding: Binding<Double> {
        let lo = 0.0003, hi = 0.01
        return Binding(
            get: { log(model.preset.blankThreshold / lo) / log(hi / lo) },
            set: { model.preset.blankThreshold = lo * pow(hi / lo, $0) }
        )
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected:
            Label("Připojeno", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connecting, .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Připojuji…")
            }
        case .failed(let msg):
            Label("Nedostupný", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(msg)
        }
    }
}
