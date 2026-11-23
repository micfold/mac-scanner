import Observation
import PrinterKit
import SwiftUI

/// The printer's job queue: what is printing, waiting and recently finished.
@MainActor
@Observable
public final class JobsModel {
  private(set) var jobs: [PrintJob] = []
  private(set) var error: String?
  private let session: DeviceSession

  public init(session: DeviceSession) {
    self.session = session
  }

  var active: [PrintJob] { jobs.filter(\.state.isActive) }
  var finished: [PrintJob] { jobs.filter { !$0.state.isActive } }

  func refresh() async {
    do {
      jobs = try await session.services.printer.jobs()
      error = nil
    } catch {
      self.error = ErrorText.describe(error)
    }
  }

  func cancel(_ job: PrintJob) async {
    do {
      try await session.services.printer.cancel(job: job.id)
      session.log.append("Zrušena úloha #\(job.id)")
    } catch {
      self.error = ErrorText.describe(error)
    }
    await refresh()
  }

  /// Refreshes every few seconds while the view is visible.
  func monitor() async {
    while !Task.isCancelled {
      await refresh()
      try? await Task.sleep(for: .seconds(3))
    }
  }
}

struct JobsView: View {
  var model: JobsModel

  var body: some View {
    List {
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      Section("Ve frontě") {
        if model.active.isEmpty {
          Text("Nic se netiskne.").foregroundStyle(.secondary)
        }
        ForEach(model.active) { job in
          JobRow(job: job) {
            Button("Zrušit", systemImage: "xmark.circle") { Task { await model.cancel(job) } }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Zrušit úlohu")
          }
        }
      }
      Section("Dokončené") {
        ForEach(model.finished) { job in JobRow(job: job) { EmptyView() } }
      }
    }
    .listStyle(.inset)
    .task { await model.monitor() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Obnovit", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
      }
    }
  }
}

private struct JobRow<Accessory: View>: View {
  var job: PrintJob
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(job.name).lineLimit(1)
        Text(details).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if job.state == .processing { ProgressView().controlSize(.small) }
      Text(job.state.label).foregroundStyle(.secondary)
      accessory
    }
    .padding(.vertical, 2)
  }

  private var details: String {
    var parts = ["#\(job.id)"]
    if let owner = job.owner { parts.append(owner) }
    if let pages = job.pagesCompleted { parts.append(plural(pages, "strana", "strany", "stran")) }
    return parts.joined(separator: " · ")
  }

  private var icon: String {
    switch job.state {
    case .processing: "printer.fill"
    case .pending, .held: "clock"
    case .completed: "checkmark.circle"
    case .canceled, .aborted: "xmark.circle"
    default: "questionmark.circle"
    }
  }

  private var tint: Color {
    switch job.state {
    case .processing: .blue
    case .completed: .green
    case .canceled, .aborted, .stopped: .orange
    default: .secondary
    }
  }
}
