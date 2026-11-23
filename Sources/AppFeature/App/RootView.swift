import PrinterKit
import SwiftUI

/// Main window: sidebar navigation between features.
public struct RootView: View {
  @Bindable var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView {
      Sidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    } detail: {
      detail
        .navigationTitle(model.section.title)
        .navigationSubtitle(model.session.displayName)
    }
    .environment(model.session)
    .sheet(isPresented: $model.showLog) { LogView(log: model.log) }
    .onChange(of: model.discovery.devices) { model.adoptDiscoveredDeviceIfNeeded() }
  }

  @ViewBuilder private var detail: some View {
    switch model.section {
    case .overview: OverviewView { model.section = $0 }
    case .scan: ScanView(model: model.scan)
    case .print: PrintView(model: model.print)
    case .jobs: JobsView(model: model.jobs)
    case .device: DeviceView()
    }
  }
}

private struct Sidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    List(selection: Binding<AppSection?>(get: { model.section }, set: { if let new = $0 { model.section = new } })) {
      Section {
        HStack(spacing: 10) {
          Image(systemName: "printer.fill")
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.quaternary, in: .rect(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 2) {
            Text(model.session.displayName).font(.headline).lineLimit(1)
            HStack(spacing: 5) {
              StatusDot(color: model.session.printer?.state.color ?? model.session.connection.color)
              Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
        .selectionDisabled()
      }
      Section("Tiskárna") {
        row(.overview)
        row(.jobs, badge: model.session.printer?.queuedJobs ?? 0)
        row(.device)
      }
      Section("Práce") {
        row(.scan)
        row(.print)
      }
    }
    .listStyle(.sidebar)
  }

  private func row(_ section: AppSection, badge: Int = 0) -> some View {
    Label(section.title, systemImage: section.systemImage)
      .badge(badge)
      .tag(section)
  }

  private var statusText: String {
    switch model.session.connection {
    case .online: model.session.printer?.state.label ?? "Připojeno"
    case .connecting: "Připojuji…"
    case .offline: "Nedostupná"
    case .notConfigured: "Vyberte v Nastavení"
    }
  }
}

/// Communication log (⌘L).
struct LogView: View {
  var log: LogStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Protokol komunikace").font(.headline)
      ScrollView {
        Text(log.lines.isEmpty ? "Zatím prázdný." : log.lines.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .defaultScrollAnchor(.bottom)
      .background(Color(nsColor: .textBackgroundColor))
      HStack {
        Button("Kopírovat vše") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(log.lines.joined(separator: "\n"), forType: .string)
        }
        Button("Ukázat soubor") { NSWorkspace.shared.activateFileViewerSelecting([LogStore.fileURL]) }
        Button("Vymazat") { log.clear() }
        Spacer()
        Button("Zavřít") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 480)
  }
}

// MARK: - Settings (⌘,)

public struct SettingsView: View {
  var model: AppModel
  @State private var hostText = ""
  @State private var queues: [String] = []

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      Section("Tiskárna") {
        HStack {
          TextField("Adresa", text: $hostText, prompt: Text("IP adresa, např. 192.168.1.50"))
            .onSubmit { model.session.connect(to: DeviceAddress(parsing: hostText)) }
          Button("Připojit") { model.session.connect(to: DeviceAddress(parsing: hostText)) }
        }
        if model.discovery.devices.isEmpty {
          Text("Hledám tiskárny v síti…").foregroundStyle(.secondary)
        }
        ForEach(model.discovery.devices) { device in
          Button {
            hostText = device.address.host
            model.session.connect(to: device.address)
          } label: {
            Label("\(device.name) — \(device.address.host)", systemImage: "printer")
          }
          .buttonStyle(.link)
        }
      }
      Section {
        Picker(
          "Fronta macOS",
          selection: Binding(get: { model.session.cupsQueue }, set: { model.session.cupsQueue = $0 })
        ) {
          Text("Nepoužívat").tag(String?.none)
          ForEach(queues, id: \.self) { Text($0).tag(String?.some($0)) }
        }
      } header: {
        Text("Záložní tisk")
      } footer: {
        Text("Použije se, jen když tiskárna nepřijímá PDF přímo přes IPP.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onAppear { hostText = model.session.address.host }
    .task { queues = await SystemPrintQueue.destinations() }
  }
}

// MARK: - Menu bar

/// Compact status + quick actions in the menu bar.
public struct MenuBarView: View {
  var model: AppModel
  @Environment(\.openWindow) private var openWindow

  public init(model: AppModel) {
    self.model = model
  }

  private func openMain(_ section: AppSection) {
    model.section = section
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        StatusDot(color: model.session.printer?.state.color ?? model.session.connection.color)
        Text(model.session.displayName).font(.headline)
        Spacer()
        Text(model.session.printer?.state.label ?? "").foregroundStyle(.secondary)
      }
      ForEach(model.session.printer?.alerts ?? [], id: \.self) { reason in
        Label(StateReasonText.describe(reason), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      ForEach(model.session.printer?.supplies ?? []) { SupplyGauge(supply: $0) }
      Divider()
      Button("Skenovat dávku", systemImage: "doc.viewfinder") { openMain(.scan) }
      Button("Tisknout soubor…", systemImage: "printer") { openMain(.print) }
      Button("Fronta úloh", systemImage: "list.bullet.rectangle") { openMain(.jobs) }
    }
    .buttonStyle(.borderless)
    .padding(14)
    .frame(width: 300)
  }
}
