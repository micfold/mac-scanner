import XCTest
@testable import ScanCore

final class CapabilitiesTests: XCTestCase {
    static let sample = """
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
              <scan:DiscreteResolution><scan:XResolution>600</scan:XResolution><scan:YResolution>600</scan:YResolution></scan:DiscreteResolution>
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
            <scan:SupportedResolutions><scan:DiscreteResolutions>
              <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
            </scan:DiscreteResolutions></scan:SupportedResolutions>
          </scan:SettingProfile></scan:SettingProfiles>
        </scan:AdfSimplexInputCaps>
        <scan:AdfOptions><scan:AdfOption>Duplex</scan:AdfOption></scan:AdfOptions>
      </scan:Adf>
    </scan:ScannerCapabilities>
    """

    func testParsesCanonLikeCapabilities() throws {
        let c = try ScannerCapabilities.parse(Data(Self.sample.utf8))
        XCTAssertEqual(c.version, "2.63")
        XCTAssertEqual(c.makeAndModel, "Canon MF750C II Series")
        XCTAssertEqual(c.platen?.resolutions, [150, 300, 600])
        XCTAssertEqual(c.platen?.colorModes, ["Grayscale8", "RGB24"])
        XCTAssertTrue(c.platen?.documentFormats.contains("image/jpeg") ?? false)
        XCTAssertEqual(c.adfSimplex?.maxHeight, 4200)
        XCTAssertTrue(c.hasFeeder)
        XCTAssertTrue(c.hasDuplex, "Duplex nahlášený přes AdfOption")
    }

    func testStatus() throws {
        let xml = """
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.63</pwg:Version><pwg:State>Idle</pwg:State>
          <scan:AdfState>ScannerAdfEmpty</scan:AdfState>
        </scan:ScannerStatus>
        """
        let s = try ScannerStatus.parse(Data(xml.utf8))
        XCTAssertTrue(s.isIdle)
        XCTAssertEqual(s.adfLoaded, false)
        XCTAssertNil(s.adfProblem)
    }

    func testStatusJobInfo() throws {
        let xml = """
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:State>Processing</pwg:State>
          <scan:Jobs>
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/1111</pwg:JobUri><pwg:JobUuid>1111</pwg:JobUuid>
              <pwg:ImagesCompleted>3</pwg:ImagesCompleted><pwg:ImagesToTransfer>0</pwg:ImagesToTransfer>
              <pwg:JobState>Completed</pwg:JobState>
            </scan:JobInfo>
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/2222</pwg:JobUri>
              <pwg:ImagesCompleted>0</pwg:ImagesCompleted><pwg:ImagesToTransfer>0</pwg:ImagesToTransfer>
              <pwg:JobState>Processing</pwg:JobState>
            </scan:JobInfo>
          </scan:Jobs>
        </scan:ScannerStatus>
        """
        let s = try ScannerStatus.parse(Data(xml.utf8))
        XCTAssertEqual(s.state, "Processing")
        XCTAssertEqual(s.jobs.count, 2)
        let running = s.job(URL(string: "http://10.0.0.5/eSCL/ScanJobs/2222")!)
        XCTAssertEqual(running?.isRunning, true)
        let done = s.job(URL(string: "http://10.0.0.5/eSCL/ScanJobs/1111")!)
        XCTAssertEqual(done?.isRunning, false)
        XCTAssertEqual(done?.imagesCompleted, 3)
        XCTAssertNil(s.job(URL(string: "http://10.0.0.5/eSCL/ScanJobs/3333")!))
    }
}

final class SettingsXMLTests: XCTestCase {
    func testFeederDuplexXML() throws {
        let caps = InputCaps(maxWidth: 2400, maxHeight: 4200, resolutions: [150, 300, 600])
        let s = ScanSettings(source: .feeder, duplex: true, colorMode: .gray, resolution: 250, paper: .a4)
        let xml = s.xml(version: "2.63", caps: caps)
        let root = try XMLTree.parse(Data(xml.utf8))
        XCTAssertEqual(root.name, "ScanSettings")
        XCTAssertEqual(root.first("Version")?.value, "2.63")
        XCTAssertEqual(root.first("InputSource")?.value, "Feeder")
        XCTAssertEqual(root.first("Duplex")?.value, "true")
        XCTAssertEqual(root.first("ColorMode")?.value, "Grayscale8")
        XCTAssertEqual(root.first("XResolution")?.value, "300", "zaokrouhleno na nejbližší podporované")
        XCTAssertEqual(root.first("Width")?.value, "2400", "omezeno maximem skeneru")
        XCTAssertEqual(root.first("Height")?.value, "3508")
        XCTAssertEqual(root.first("DocumentFormat")?.value, "image/jpeg")
    }

    func testPlatenHasNoDuplex() {
        let xml = ScanSettings(source: .platen, duplex: true).xml()
        XCTAssertFalse(xml.contains("Duplex"))
        XCTAssertTrue(xml.contains("<pwg:InputSource>Platen</pwg:InputSource>"))
    }

    func testLocationResolution() {
        let ep = ESCLEndpoint(host: "192.168.1.50")
        XCTAssertEqual(ep.baseURL.absoluteString, "http://192.168.1.50/eSCL")
        XCTAssertEqual(ep.resolve(location: "http://canon-mf750.local:80/eSCL/ScanJobs/abc")?.absoluteString,
                       "http://192.168.1.50/eSCL/ScanJobs/abc")
        XCTAssertEqual(ep.resolve(location: "/eSCL/ScanJobs/xyz")?.absoluteString,
                       "http://192.168.1.50/eSCL/ScanJobs/xyz")
    }
}

final class SplitterTests: XCTestCase {
    /// Pomocník: duplexní dávka z popisu listů, např. ["XX", "X_", "__", "XX"] (X = obsah, _ = prázdno)
    func duplex(_ sheets: [String]) -> [PageMeta] {
        sheets.enumerated().flatMap { (i, s) in s.map { PageMeta(isBlank: $0 == "_", sheet: i) } }
    }
    func simplex(_ s: String) -> [PageMeta] {
        s.enumerated().map { PageMeta(isBlank: $1 == "_", sheet: $0) }
    }

    func testDuplexBlankBackDoesNotSplit() {
        // dvě jednostranné faktury za sebou bez oddělovače → 1 dokument, prázdné ruby pryč
        let docs = DocumentSplitter.split(duplex(["X_", "X_"]), options: SplitOptions(mode: .blankSeparator))
        XCTAssertEqual(docs, [[0, 2]])
    }

    func testDuplexBlankSheetSeparates() {
        let pages = duplex(["XX", "X_", "__", "XX", "__", "__", "X_"])
        let docs = DocumentSplitter.split(pages, options: SplitOptions(mode: .blankSeparator))
        XCTAssertEqual(docs, [[0, 1, 2], [6, 7], [12]])
    }

    func testKeepBlankPagesWhenAsked() {
        let docs = DocumentSplitter.split(duplex(["X_", "__", "XX"]),
                                          options: SplitOptions(mode: .blankSeparator, removeBlankPages: false))
        XCTAssertEqual(docs, [[0, 1], [4, 5]])
    }

    func testSimplexSeparator() {
        let docs = DocumentSplitter.split(simplex("XX_X__XX"), options: SplitOptions(mode: .blankSeparator))
        XCTAssertEqual(docs, [[0, 1], [3], [6, 7]])
    }

    func testSingleEachAndEveryN() {
        let p = simplex("XX_XX")
        XCTAssertEqual(DocumentSplitter.split(p, options: SplitOptions(mode: .single)), [[0, 1, 3, 4]])
        XCTAssertEqual(DocumentSplitter.split(p, options: SplitOptions(mode: .eachPage)), [[0], [1], [3], [4]])
        XCTAssertEqual(DocumentSplitter.split(p, options: SplitOptions(mode: .everyN, everyN: 3)), [[0, 1, 3], [4]])
        XCTAssertEqual(DocumentSplitter.split([], options: SplitOptions(mode: .single)), [])
    }
}

final class NamingTests: XCTestCase {
    func testPattern() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 22; comps.hour = 9; comps.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(FileNamer(pattern: "Faktura_{datum}_{č}").name(index: 3, date: date), "Faktura_2026-11-22_3")
        XCTAssertEqual(FileNamer(pattern: "{date} {time}/x").name(index: 1, date: date), "2026-11-22 09-05-x")
        XCTAssertEqual(FileNamer(pattern: "").name(index: 1, date: date), "Sken_2026-11-22_1")
    }

    func testUniqueURL() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/A.pdf", "/tmp/x/A (2).pdf"]
        let u = FileNamer.uniqueURL(in: folder, base: "A", ext: "pdf") { taken.contains($0.path) }
        XCTAssertEqual(u.lastPathComponent, "A (3).pdf")
    }
}
