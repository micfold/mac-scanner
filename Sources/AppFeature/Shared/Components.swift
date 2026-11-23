import PrinterKit
import SwiftUI

/// Rounded panel used for grouping on every screen.
struct Card<Content: View>: View {
  var title: String?
  var systemImage: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        Label(title, systemImage: systemImage ?? "")
          .labelStyle(.titleAndIcon)
          .font(.headline)
      }
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
  }
}

struct StatusDot: View {
  var color: Color
  var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

extension DeviceSession.Connection {
  var color: Color {
    switch self {
    case .online: .green
    case .connecting: .yellow
    case .offline: .orange
    case .notConfigured: .gray
    }
  }
}

extension PrinterState {
  var color: Color {
    switch self {
    case .idle: .green
    case .processing: .blue
    case .stopped: .orange
    case .unknown: .gray
    }
  }
}

/// One consumable: coloured bar + percentage.
struct SupplyGauge: View {
  var supply: Supply

  var body: some View {
    HStack(spacing: 10) {
      Text(supply.localizedName).frame(width: 82, alignment: .leading)
      ProgressView(value: Double(supply.level ?? 0), total: 100)
        .tint(supply.swatch)
        .opacity(supply.level == nil ? 0.3 : 1)
      Text(supply.level.map { "\($0) %" } ?? "?")
        .monospacedDigit()
        .foregroundStyle(supply.isLow ? .orange : .secondary)
        .frame(width: 44, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }
}

extension Supply {
  var swatch: Color {
    guard let hex = color?.split(separator: "#").first.map(String.init), hex.count == 6,
      let value = Int(hex, radix: 16)
    else { return .gray }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }

  var localizedName: String {
    let names = ["cyan": "Azurová", "magenta": "Purpurová", "yellow": "Žlutá", "black": "Černá"]
    let lower = name.lowercased()
    return names.first { lower.contains($0.key) }?.value ?? name
  }
}

/// Dashed drop target.
struct DropZone: View {
  var title: String
  var systemImage: String
  var isTargeted: Bool

  var body: some View {
    Label(title, systemImage: systemImage)
      .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
      .frame(maxWidth: .infinity, minHeight: 64)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
          .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
  }
}

/// Inline message strip used for errors and confirmations.
struct Banner: Equatable {
  enum Kind { case info, success, error }
  var kind: Kind
  var text: String
  var files: [URL] = []
}

struct BannerView: View {
  var banner: Banner
  var onClose: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon).foregroundStyle(tint)
      Text(banner.text).fixedSize(horizontal: false, vertical: true)
      Spacer()
      if !banner.files.isEmpty {
        Button("Ukázat ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting(banner.files) }
      }
      Button("Zavřít", systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(tint.opacity(0.12))
  }

  private var icon: String {
    switch banner.kind {
    case .info: "info.circle.fill"
    case .success: "checkmark.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch banner.kind {
    case .info: .blue
    case .success: .green
    case .error: .orange
    }
  }
}
