import Foundation
import Testing

@testable import PrinterKit

@Suite("IPP encoding")
struct IPPEncodingTests {
  @Test func encodesGetPrinterAttributesExactly() {
    let message = IPPMessage(
      code: IPPOperation.getPrinterAttributes, requestID: 1,
      groups: [
        IPPAttributeGroup(
          tag: IPPTag.operationAttributes,
          attributes: [
            IPPAttribute("attributes-charset", .charset("utf-8")),
            IPPAttribute("requested-attributes", [.keyword("a"), .keyword("b")]),
          ])
      ])
    var expected: [UInt8] = [0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x01, 0x01]
    expected += [0x47, 0x00, 0x12] + Array("attributes-charset".utf8)
    expected += [0x00, 0x05] + Array("utf-8".utf8)
    expected += [0x44, 0x00, 0x14] + Array("requested-attributes".utf8)
    expected += [0x00, 0x01, 0x61]
    expected += [0x44, 0x00, 0x00, 0x00, 0x01, 0x62]
    expected += [0x03]
    #expect(Array(message.encoded()) == expected)
  }

  @Test func decodesHandWrittenResponse() throws {
    // status successful-ok, printer group: printer-state=3 (enum), marker-levels=[80, -1]
    var bytes: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x04]
    bytes += [0x23, 0x00, 0x0D] + Array("printer-state".utf8)
    bytes += [0x00, 0x04, 0x00, 0x00, 0x00, 0x03]
    bytes += [0x21, 0x00, 0x0D] + Array("marker-levels".utf8)
    bytes += [0x00, 0x04, 0x00, 0x00, 0x00, 0x50]
    bytes += [0x21, 0x00, 0x00, 0x00, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
    bytes += [0x03]
    let message = try IPPMessage.decode(Data(bytes))
    #expect(message.isSuccess)
    #expect(message.requestID == 7)
    #expect(message.attribute("printer-state", in: IPPTag.printerAttributes)?.ints == [3])
    #expect(message.attribute("marker-levels", in: IPPTag.printerAttributes)?.ints == [80, -1])
  }

  @Test func collectionsRoundTrip() throws {
    let original = IPPMessage(
      code: 0, requestID: 42,
      groups: [IPPAttributeGroup(tag: IPPTag.printerAttributes, attributes: Fixtures.printerAttributes)],
      document: Data("%PDF".utf8))
    let decoded = try IPPMessage.decode(original.encoded())
    #expect(decoded == original)
  }

  @Test func rejectsTruncatedMessages() {
    #expect(throws: IPPError.self) { try IPPMessage.decode(Data([0x02, 0x00, 0x00])) }
  }
}

@Suite("Printer info")
struct PrinterInfoTests {
  let info = PrinterInfo(Fixtures.printerAttributes)

  @Test func basics() {
    #expect(info.makeAndModel == "Canon MF750C II Series")
    #expect(info.state == .idle)
    #expect(info.alerts.isEmpty)
    #expect(info.webPage?.absoluteString == "http://192.168.1.50/")
  }

  @Test func supplies() {
    #expect(info.supplies.map(\.name) == ["Cyan", "Magenta", "Yellow", "Black"])
    #expect(info.supplies.map(\.level) == [80, 80, nil, 90], "-3 means 'some remaining' = unknown level")
    #expect(info.supplies[0].color == "#00FFFF")
  }

  @Test func trays() {
    #expect(info.trays.count == 2)
    #expect(info.trays[0].source == "tray-1")
    #expect(info.trays[0].media == "iso_a4_210x297mm")
    #expect(info.trays[0].level == 80)
    #expect(info.trays[1].source == "by-pass-tray")
    #expect(info.trays[1].media == "iso_dl_110x220mm")
    #expect(info.trays[1].level == 0)
  }

  @Test func capabilities() {
    let caps = info.capabilities
    #expect(caps.acceptsPDF)
    #expect(caps.copies == 1...999)
    #expect(caps.sides == [.oneSided, .longEdge, .shortEdge])
    #expect(caps.qualities == [.normal, .high])
    #expect(caps.media.contains("iso_a5_148x210mm"))
    #expect(!caps.media.contains { $0.hasPrefix("custom_") })
    #expect(caps.numberUp == [1, 2, 4, 6, 9, 16])
    #expect(caps.pageRanges)
  }
}

@Suite("Print ticket")
struct PrintTicketTests {
  let caps = PrinterInfo(Fixtures.printerAttributes).capabilities

  @Test func defaultTicketIsMinimal() {
    let names = PrintTicket().ippJobAttributes(for: caps).map(\.name)
    #expect(names == ["sides", "print-quality"])
  }

  @Test func fullTicket() {
    var ticket = PrintTicket()
    ticket.copies = 2
    ticket.sides = .longEdge
    ticket.colorMode = .monochrome
    ticket.quality = .draft  // not supported by fixture → omitted
    ticket.numberUp = 2
    ticket.pageRanges = [1...3, 5...5]
    ticket.media = "iso_a5_148x210mm"
    let attributes = ticket.ippJobAttributes(for: caps)
    #expect(attributes["copies"]?.ints == [2])
    #expect(attributes["sides"]?.strings == ["two-sided-long-edge"])
    #expect(attributes["print-color-mode"]?.strings == ["monochrome"])
    #expect(attributes["print-quality"] == nil)
    #expect(attributes["number-up"]?.ints == [2])
    #expect(attributes["page-ranges"]?.values == [.range(lower: 1, upper: 3), .range(lower: 5, upper: 5)])
    #expect(attributes["media"]?.strings == ["iso_a5_148x210mm"])
  }

  @Test func sourceUsesMediaCol() throws {
    var ticket = PrintTicket()
    ticket.mediaSource = "by-pass-tray"
    ticket.media = "iso_dl_110x220mm"
    let mediaCol = try #require(ticket.ippJobAttributes(for: caps)["media-col"]?.values.first?.members)
    #expect(mediaCol["media-source"]?.strings == ["by-pass-tray"])
    let size = try #require(mediaCol["media-size"]?.values.first?.members)
    #expect(size["x-dimension"]?.ints == [11000])
    #expect(size["y-dimension"]?.ints == [22000])
  }

  @Test(arguments: [
    ("", [ClosedRange<Int>]()),
    ("1-3, 5", [1...3, 5...5]),
    ("2-", [2...10]),
    (" 7 ", [7...7]),
  ])
  func parsesPageRanges(input: String, expected: [ClosedRange<Int>]) {
    #expect(PrintTicket.parsePageRanges(input, pageCount: 10) == expected)
  }

  @Test(arguments: ["0", "3-1", "a", "1-2-3"])
  func rejectsBadPageRanges(input: String) {
    #expect(PrintTicket.parsePageRanges(input) == nil)
  }

  @Test func lpOptions() {
    var ticket = PrintTicket()
    ticket.copies = 3
    ticket.sides = .shortEdge
    ticket.pageRanges = [1...2]
    #expect(ticket.lpOptions.contains("sides=two-sided-short-edge"))
    #expect(ticket.lpOptions.contains("page-ranges=1-2"))
    #expect(ticket.lpOptions.prefix(2) == ["-n", "3"])
  }
}

@Suite("Media names")
struct MediaSizeTests {
  @Test(arguments: [
    ("iso_a4_210x297mm", "A4", 21000, 29700),
    ("na_letter_8.5x11in", "Letter", 21590, 27940),
    ("iso_dl_110x220mm", "DL envelope", 11000, 22000),
    ("jis_b5_182x257mm", "B5 (JIS)", 18200, 25700),
    ("iso_c5_162x229mm", "C5 envelope", 16200, 22900),
  ])
  func parses(keyword: String, name: String, width: Int, height: Int) throws {
    let size = try #require(MediaSize(keyword: keyword))
    #expect(size.displayName == name)
    #expect(size.width == width)
    #expect(size.height == height)
  }

  @Test func rejectsNonPWG() {
    #expect(MediaSize(keyword: "A4") == nil)
  }
}

@Suite("IPP client")
struct IPPClientTests {
  @Test func printSendsPDFAndReturnsJobID() async throws {
    let client = IPPClient(
      printerURI: URL(string: "ipp://192.168.1.50/ipp/print")!,
      transport: FakeTransport { request in
        #expect(request.url.absoluteString == "http://192.168.1.50:631/ipp/print")
        #expect(request.headers["Content-Type"] == "application/ipp")
        let sent = try IPPMessage.decode(request.body ?? Data())
        #expect(sent.code == IPPOperation.printJob)
        #expect(sent.attribute("document-format", in: IPPTag.operationAttributes)?.strings == ["application/pdf"])
        #expect(sent.document == Data("%PDF-1.7".utf8))
        let reply = IPPMessage(
          code: 0, requestID: sent.requestID,
          groups: [
            IPPAttributeGroup(tag: IPPTag.operationAttributes, attributes: []),
            IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: [IPPAttribute("job-id", .integer(17))]),
          ])
        return HTTPResponse(status: 200, body: reply.encoded())
      })
    let id = try await client.print(
      Data("%PDF-1.7".utf8), format: "application/pdf", jobName: "test.pdf", ticket: PrintTicket(), capabilities: nil)
    #expect(id == 17)
  }

  @Test func errorStatusThrows() async {
    let client = IPPClient(
      printerURI: URL(string: "ipp://h/ipp/print")!,
      transport: FakeTransport { _ in
        let reply = IPPMessage(
          code: 0x040B, requestID: 1,
          groups: [
            IPPAttributeGroup(
              tag: IPPTag.operationAttributes, attributes: [IPPAttribute("status-message", .text("bad format"))])
          ])
        return HTTPResponse(status: 200, body: reply.encoded())
      })
    await #expect(throws: IPPError.status(code: 0x040B, message: "bad format")) { try await client.identify() }
  }
}
