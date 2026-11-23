import Foundation

@testable import PrinterKit

enum Fixtures {
  static let scannerCapabilities = Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
      <pwg:Version>2.63</pwg:Version>
      <pwg:MakeAndModel>Canon MF750C II Series</pwg:MakeAndModel>
      <scan:Platen>
        <scan:PlatenInputCaps>
          <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>2551</scan:MaxWidth>
          <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
          <scan:SettingProfiles><scan:SettingProfile>
            <scan:ColorModes><scan:ColorMode>Grayscale8</scan:ColorMode><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
            <scan:DocumentFormats><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
            <scan:SupportedResolutions><scan:DiscreteResolutions>
              <scan:DiscreteResolution><scan:XResolution>150</scan:XResolution><scan:YResolution>150</scan:YResolution></scan:DiscreteResolution>
              <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
            </scan:DiscreteResolutions></scan:SupportedResolutions>
          </scan:SettingProfile></scan:SettingProfiles>
        </scan:PlatenInputCaps>
      </scan:Platen>
      <scan:Adf>
        <scan:AdfSimplexInputCaps>
          <scan:MaxWidth>2551</scan:MaxWidth><scan:MaxHeight>4200</scan:MaxHeight>
          <scan:SettingProfiles><scan:SettingProfile>
            <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
            <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
          </scan:SettingProfile></scan:SettingProfiles>
        </scan:AdfSimplexInputCaps>
        <scan:AdfOptions><scan:AdfOption>Duplex</scan:AdfOption></scan:AdfOptions>
      </scan:Adf>
    </scan:ScannerCapabilities>
    """.utf8)

  static func scannerStatus(feeder: String = "ScannerAdfLoaded", jobs: [(id: String, state: String)] = []) -> Data {
    let jobXML = jobs.map {
      "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\($0.id)</pwg:JobUri><pwg:JobState>\($0.state)</pwg:JobState></scan:JobInfo>"
    }.joined()
    return Data(
      """
      <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
        <pwg:State>Idle</pwg:State><scan:AdfState>\(feeder)</scan:AdfState><scan:Jobs>\(jobXML)</scan:Jobs>
      </scan:ScannerStatus>
      """.utf8)
  }

  /// Printer attributes as a Canon MF750C II reports them (abridged).
  static let printerAttributes: [IPPAttribute] = [
    IPPAttribute("printer-name", .name("Canon MF750C II Series")),
    IPPAttribute("printer-make-and-model", .text("Canon MF750C II Series")),
    IPPAttribute("printer-more-info", .uri("http://192.168.1.50/")),
    IPPAttribute("printer-state", .enumeration(3)),
    IPPAttribute("printer-state-reasons", [.keyword("none")]),
    IPPAttribute("printer-is-accepting-jobs", .boolean(true)),
    IPPAttribute("marker-names", [.name("Cyan"), .name("Magenta"), .name("Yellow"), .name("Black")]),
    IPPAttribute("marker-colors", [.name("#00FFFF"), .name("#FF00FF"), .name("#FFFF00"), .name("#000000")]),
    IPPAttribute("marker-levels", [.integer(80), .integer(80), .integer(-3), .integer(90)]),
    IPPAttribute("marker-types", [.keyword("toner"), .keyword("toner"), .keyword("toner"), .keyword("toner")]),
    IPPAttribute(
      "printer-input-tray",
      [
        .octets(
          Data(
            "type=sheetFeedAutoRemovableTray;mediafeed=0;mediaxfeed=0;maxcapacity=250;level=200;status=0;name=Tray 1;"
              .utf8), tag: IPPTag.octetString),
        .octets(
          Data(
            "type=sheetFeedManual;mediafeed=0;mediaxfeed=0;maxcapacity=50;level=0;status=0;name=Multi-purpose Tray;"
              .utf8), tag: IPPTag.octetString),
      ]),
    IPPAttribute(
      "media-col-ready",
      [
        .collection([
          IPPAttribute(
            "media-size",
            .collection([IPPAttribute("x-dimension", .integer(21000)), IPPAttribute("y-dimension", .integer(29700))])),
          IPPAttribute("media-source", .keyword("tray-1")),
          IPPAttribute("media-type", .keyword("stationery")),
        ]),
        .collection([
          IPPAttribute(
            "media-size",
            .collection([IPPAttribute("x-dimension", .integer(11000)), IPPAttribute("y-dimension", .integer(22000))])),
          IPPAttribute("media-source", .keyword("by-pass-tray")),
          IPPAttribute("media-type", .keyword("envelope")),
        ]),
      ]),
    IPPAttribute(
      "document-format-supported", [.mimeType("application/pdf"), .mimeType("image/urf"), .mimeType("image/jpeg")]),
    IPPAttribute("copies-supported", .range(lower: 1, upper: 999)),
    IPPAttribute(
      "sides-supported", [.keyword("one-sided"), .keyword("two-sided-long-edge"), .keyword("two-sided-short-edge")]),
    IPPAttribute("print-color-mode-supported", [.keyword("auto"), .keyword("color"), .keyword("monochrome")]),
    IPPAttribute("print-quality-supported", [.enumeration(4), .enumeration(5)]),
    IPPAttribute(
      "media-supported",
      [
        .keyword("iso_a4_210x297mm"), .keyword("iso_a5_148x210mm"), .keyword("na_letter_8.5x11in"),
        .keyword("iso_dl_110x220mm"), .keyword("custom_min_76.2x127mm"),
      ]),
    IPPAttribute("media-default", .keyword("iso_a4_210x297mm")),
    IPPAttribute("media-source-supported", [.keyword("auto"), .keyword("tray-1"), .keyword("by-pass-tray")]),
    IPPAttribute("number-up-supported", .range(lower: 1, upper: 16)),
    IPPAttribute("page-ranges-supported", .boolean(true)),
  ]
}

/// A transport that answers from a closure. State lives in the caller (usually an actor).
struct FakeTransport: HTTPTransport {
  let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
  func send(_ request: HTTPRequest) async throws -> HTTPResponse { try await handler(request) }
}
