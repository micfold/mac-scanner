import SwiftUI
import AppKit
import ScanCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            SettingsPanel()
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            BatchView()
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Skener")
        .navigationSubtitle(model.connectionSubtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Předvolba", selection: $model.selectedPresetID) {
                    ForEach(model.presets) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.isBusy)
                .help("Předvolba skenování")
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button {
                        model.cancelScan()
                    } label: {
                        Label("Zastavit", systemImage: "stop.fill")
                    }
                    .help("Zastavit skenování (⌘.)")
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Skenovat", systemImage: "doc.viewfinder")
                    }
                    .disabled(model.isBusy)
                    .help("Naskenovat dávku (⌘R)")
                }
            }
        }
        .task {
            model.discovery.start()
            await model.monitor()
        }
        .onChange(of: model.discovery.found) { _, found in
            // Bez zadané adresy použijeme první skener nalezený v síti.
            if model.endpoint.host.isEmpty, let first = found.first { model.use(first) }
        }
        .sheet(item: previewBinding) { page in
            PagePreview(page: page)
        }
        .sheet(isPresented: $model.showLog) {
            LogView()
        }
    }

    private var previewBinding: Binding<ScannedPage?> {
        Binding(
            get: { model.previewPageID.flatMap { model.pages[$0] } },
            set: { model.previewPageID = $0?.id }
        )
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protokol komunikace se skenerem").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logLines.isEmpty ? "Zatím prázdný – spusťte skenování." : model.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { proxy.scrollTo("end") }
            }
            HStack {
                Button("Kopírovat vše") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
                }
                Button("Ukázat soubor ve Finderu") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL])
                }
                Button("Vymazat") { model.logLines.removeAll() }
                Spacer()
                Button("Zavřít") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 480, idealHeight: 600)
    }
}

struct PagePreview: View {
    let page: ScannedPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            if let img = NSImage(data: page.jpeg) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(page.rotation)))
                    .frame(minWidth: 500, idealWidth: 640, minHeight: 600, idealHeight: 820)
            }
            HStack {
                Text("Obsah stránky: \(String(format: "%.2f", page.inkRatio * 100)) % plochy · \(page.dpi) dpi")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zavřít") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
