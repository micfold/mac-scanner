import Foundation
import PrinterKit
import Testing

@testable import AppFeature

@MainActor
@Suite("Features with the sample device")
struct AppFeatureTests {
  @Test func sessionLoadsPrinterAndScanner() async {
    let model = AppModel.preview()
    await model.session.refresh()
    #expect(model.session.connection == .online)
    #expect(model.session.printer?.supplies.count == 4)
    #expect(model.session.scannerCapabilities?.hasDuplex == true)
  }

  @Test func scanSplitsBatchAndDropsBlankPage() async throws {
    let model = AppModel(factory: SampleDevice.factory, preferences: .ephemeral(), log: LogStore(writeToDisk: false))
    model.session.connect(to: SampleDevice.address)
    await model.session.refresh()
    model.scan.preset.split = SplitOptions(mode: .blankSeparator)
    model.scan.preset.scan = ScanSettings(source: .feeder, duplex: false)
    model.scan.scan()
    while model.scan.isBusy { try await Task.sleep(for: .milliseconds(20)) }
    // Sample scanner: 6 pages, the 4th blank → separator.
    #expect(model.scan.documents.map(\.pageIDs.count) == [3, 2])
    #expect(model.scan.removedPageIDs.count == 1)
  }

  @Test func printPresetSetsTicketAndEditsClearIt() throws {
    let model = AppModel.preview()
    let economy = try #require(model.print.presets.first { $0.name == "Úsporně" })
    model.print.apply(economy)
    #expect(model.print.ticket.colorMode == .monochrome)
    #expect(model.print.isActive(economy))
    model.print.ticket.copies = 3
    #expect(!model.print.isActive(economy))
  }

  @Test func pageRangesValidateAgainstDocument() {
    let model = AppModel.preview()
    model.print.pageRangeText = "2-"
    #expect(model.print.pageRangeIsValid)
    #expect(model.print.ticket.pageRanges == [2...3])
    model.print.pageRangeText = "x"
    #expect(!model.print.pageRangeIsValid)
  }

  @Test func letterheadOverlayKeepsPageCount() throws {
    let merged = try PrintComposer.overlay(PrintComposer.samplePDF(pages: 3), on: PrintComposer.sampleLetterhead())
    #expect(PrintComposer.pdfDocument(merged)?.numberOfPages == 3)
  }

  @Test func blankDetection() throws {
    let blank = try PageImaging.page(
      from: SampleDevice.pageJPEG(seed: 0, blank: true), requestedDPI: 150, sheet: 0, blankThreshold: 0.0015)
    let text = try PageImaging.page(
      from: SampleDevice.pageJPEG(seed: 0), requestedDPI: 150, sheet: 0, blankThreshold: 0.0015)
    #expect(blank.isBlank)
    #expect(!text.isBlank)
  }
}
