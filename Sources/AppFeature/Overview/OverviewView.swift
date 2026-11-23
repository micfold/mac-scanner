import PrinterKit
import SwiftUI
import WebKit

/// The dashboard: state, alerts, supplies, paper and quick actions.
struct OverviewView: View {
  @Environment(DeviceSession.self) private var session
  var navigate: (AppSection) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if let alerts = session.printer?.alerts, !alerts.isEmpty {
          Card(title: "Upozornění", systemImage: "exclamationmark.triangle") {
            ForEach(alerts, id: \.self) { reason in
              Label(
                StateReasonText.describe(reason),
                systemImage: StateReasonText.isError(reason) ? "xmark.octagon" : "exclamationmark.circle"
              )
              .foregroundStyle(StateReasonText.isError(reason) ? .red : .orange)
            }
          }
        }
        quickActions
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
          supplies
          paper
        }
      }
      .padding(24)
    }
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var header: some View {
    Card {
      HStack(spacing: 16) {
        Image(systemName: "printer.fill")
          .font(.system(size: 34))
          .foregroundStyle(.secondary)
          .frame(width: 64, height: 64)
          .background(.quaternary, in: .rect(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 4) {
          Text(session.displayName).font(.title2.weight(.semibold))
          Text([session.address.host, session.printer?.location].compactMap { $0 }.joined(separator: " · "))
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 6) {
          if let printer = session.printer {
            Label(printer.state.label, systemImage: "circle.fill")
              .foregroundStyle(printer.state.color)
              .labelStyle(StatusLabelStyle())
          }
          if let status = session.scannerStatus {
            Label(status.isIdle ? "Skener připraven" : "Skener pracuje", systemImage: "circle.fill")
              .foregroundStyle(status.isIdle ? .green : .blue)
              .labelStyle(StatusLabelStyle())
          }
          if case .offline(let message) = session.connection {
            Text(message).foregroundStyle(.orange).font(.callout)
          }
        }
      }
    }
  }

  private var quickActions: some View {
    HStack(spacing: 12) {
      ActionTile(title: "Dávkové skenování", detail: "Podavač, OCR, rozdělení", systemImage: "doc.viewfinder") {
        navigate(.scan)
      }
      ActionTile(title: "Tisk", detail: "Předvolby, oboustranně, podklad", systemImage: "printer") { navigate(.print) }
      ActionTile(
        title: "Fronta", detail: plural(session.printer?.queuedJobs ?? 0, "úloha", "úlohy", "úloh"),
        systemImage: "list.bullet.rectangle"
      ) { navigate(.jobs) }
      ActionTile(title: "Tiskárna", detail: "Informace a nastavení", systemImage: "gearshape") { navigate(.device) }
    }
  }

  private var supplies: some View {
    Card(title: "Toner", systemImage: "drop") {
      if let supplies = session.printer?.supplies, !supplies.isEmpty {
        ForEach(supplies) { SupplyGauge(supply: $0) }
      } else {
        Text("Tiskárna stav toneru nehlásí.").foregroundStyle(.secondary)
      }
    }
  }

  private var paper: some View {
    Card(title: "Papír", systemImage: "tray.2") {
      if let trays = session.printer?.trays, !trays.isEmpty {
        ForEach(trays) { tray in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(MediaText.source(tray.source).replacingOccurrences(of: "Automaticky", with: tray.name))
              Text(
                [MediaText.name(tray.media), MediaText.type(tray.mediaType)].compactMap { $0 }.joined(separator: " · ")
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            if tray.level == 0 {
              Text("Prázdný").foregroundStyle(.orange)
            } else if let level = tray.level {
              Gauge(value: Double(level), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .frame(width: 80)
            } else {
              Text("Vloženo").foregroundStyle(.secondary)
            }
          }
        }
      } else {
        Text("Tiskárna stav zásobníků nehlásí.").foregroundStyle(.secondary)
      }
    }
  }
}

private struct ActionTile: View {
  var title: String
  var detail: String
  var systemImage: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: systemImage).font(.title2).foregroundStyle(Color.accentColor)
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(.background, in: .rect(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
    .buttonStyle(.plain)
  }
}

struct StatusLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 8))
      configuration.title.foregroundStyle(.primary)
    }
  }
}

// MARK: - Device

/// Printer details, identify, and the printer's own web interface for everything else.
struct DeviceView: View {
  @Environment(DeviceSession.self) private var session
  @State private var showWeb = false
  @State private var identifyResult: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Tiskárna") {
          LabeledContent("Model", value: session.displayName)
          LabeledContent("Adresa", value: session.address.host.isEmpty ? "—" : session.address.host)
          if let printer = session.printer {
            LabeledContent("Stav", value: printer.stateMessage ?? printer.state.label)
            if let firmware = printer.firmware { LabeledContent("Firmware", value: firmware) }
            if let location = printer.location { LabeledContent("Umístění", value: location) }
            LabeledContent("Formáty", value: printer.capabilities.documentFormats.joined(separator: ", "))
          }
          if let caps = session.scannerCapabilities {
            LabeledContent(
              "Skener",
              value: [
                caps.platen != nil ? "sklo" : nil, caps.hasFeeder ? "podavač" : nil,
                caps.hasDuplex ? "oboustranně" : nil,
              ]
              .compactMap { $0 }.joined(separator: ", "))
          }
        }
        Section("Akce") {
          Button("Najít tiskárnu (pípne a blikne)") {
            Task {
              do {
                try await session.services.printer.identify()
                identifyResult = "Tiskárna by se měla ozvat."
              } catch {
                identifyResult = ErrorText.describe(error)
              }
            }
          }
          if let identifyResult { Text(identifyResult).foregroundStyle(.secondary) }
          Button(showWeb ? "Skrýt webové rozhraní" : "Nastavení tiskárny (webové rozhraní)") { showWeb.toggle() }
          if let url = session.printer?.webPage ?? session.address.webInterface {
            Link("Otevřít v prohlížeči", destination: url)
          }
        }
      }
      .formStyle(.grouped)
      .frame(maxHeight: showWeb ? 360 : .infinity)
      if showWeb, let url = session.printer?.webPage ?? session.address.webInterface {
        Divider()
        WebView(url: url)
      }
    }
  }
}

struct WebView: NSViewRepresentable {
  var url: URL

  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.load(URLRequest(url: url))
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    if view.url?.host != url.host { view.load(URLRequest(url: url)) }
  }
}
