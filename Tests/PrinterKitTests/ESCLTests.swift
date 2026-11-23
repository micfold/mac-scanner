import Foundation
import Testing

@testable import PrinterKit

@Suite("eSCL models")
struct ESCLModelTests {
  @Test func parsesCanonCapabilities() throws {
    let caps = try ScannerCapabilities.parse(Fixtures.scannerCapabilities)
    #expect(caps.version == "2.63")
    #expect(caps.makeAndModel == "Canon MF750C II Series")
    #expect(caps.platen?.resolutions == [150, 300])
    #expect(caps.platen?.colorModes == ["Grayscale8", "RGB24"])
    #expect(caps.adfSimplex?.maxHeight == 4200)
    #expect(caps.hasFeeder)
    #expect(caps.hasDuplex, "duplex announced only via AdfOption")
  }

  @Test func parsesStatusWithJobs() throws {
    let status = try ScannerStatus.parse(
      Fixtures.scannerStatus(feeder: "ScannerAdfEmpty", jobs: [("1111", "Completed"), ("2222", "Processing")]))
    #expect(status.isIdle)
    #expect(status.feeder == .empty)
    #expect(status.job(URL(string: "http://h/eSCL/ScanJobs/2222")!)?.isRunning == true)
    #expect(status.job(URL(string: "http://h/eSCL/ScanJobs/1111")!)?.isRunning == false)
    #expect(status.job(URL(string: "http://h/eSCL/ScanJobs/3333")!) == nil)
  }

  @Test func settingsXMLClampsToCapabilities() throws {
    let caps = InputCaps(maxWidth: 2400, maxHeight: 4200, colorModes: ["RGB24"], resolutions: [150, 300])
    let settings = ScanSettings(source: .feeder, duplex: true, colorMode: .grayscale, resolution: 250, paper: .a4)
    let root = try XElement.parse(Data(settings.xml(version: "2.63", caps: caps).utf8))
    #expect(root.name == "ScanSettings")
    #expect(root.first("InputSource")?.value == "Feeder")
    #expect(root.first("Duplex")?.value == "true")
    #expect(root.first("ColorMode")?.value == "RGB24", "unsupported grayscale falls back to colour")
    #expect(root.first("XResolution")?.value == "300", "rounded to nearest supported")
    #expect(root.first("Width")?.value == "2400", "clamped to scanner maximum")
    #expect(root.first("Height")?.value == "3508")
  }

  @Test func platenHasNoDuplexElement() {
    let xml = ScanSettings(source: .platen, duplex: true).xml()
    #expect(!xml.contains("Duplex"))
    #expect(xml.contains("<pwg:InputSource>Platen</pwg:InputSource>"))
  }

  @Test func resolvesJobLocationAgainstOurHost() {
    let endpoint = ESCLEndpoint(host: "192.168.1.50")
    #expect(endpoint.baseURL.absoluteString == "http://192.168.1.50/eSCL")
    #expect(
      endpoint.resolve(location: "http://canon-mf750.local:80/eSCL/ScanJobs/abc")?.absoluteString
        == "http://192.168.1.50/eSCL/ScanJobs/abc")
    #expect(endpoint.resolve(location: "/eSCL/ScanJobs/xyz")?.absoluteString == "http://192.168.1.50/eSCL/ScanJobs/xyz")
  }
}

/// A scripted scanner that answers NextDocument with 404 until the first page is ready,
/// like Canon i-SENSYS / imageCLASS firmware does.
actor CanonLikeScanner {
  var pagesLeft: Int
  var early404s: Int
  private(set) var deletes = 0
  private let jobID = "job-1"

  init(pages: Int, early404s: Int = 3) {
    pagesLeft = pages
    self.early404s = early404s
  }

  func handle(_ request: HTTPRequest) -> HTTPResponse {
    let path = request.url.path
    switch (request.method, path) {
    case ("GET", "/eSCL/ScannerCapabilities"):
      return HTTPResponse(status: 200, body: Fixtures.scannerCapabilities)
    case ("GET", "/eSCL/ScannerStatus"):
      let state = pagesLeft > 0 ? "Processing" : "Completed"
      return HTTPResponse(status: 200, body: Fixtures.scannerStatus(jobs: [(jobID, state)]))
    case ("POST", "/eSCL/ScanJobs"):
      return HTTPResponse(status: 201, headers: ["Location": "http://canon.local:80/eSCL/ScanJobs/\(jobID)"])
    case ("GET", "/eSCL/ScanJobs/\(jobID)/NextDocument"):
      if early404s > 0 {
        early404s -= 1
        return HTTPResponse(status: 404)
      }
      guard pagesLeft > 0 else { return HTTPResponse(status: 404) }
      pagesLeft -= 1
      return HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xD9]))
    case ("DELETE", _):
      deletes += 1
      return HTTPResponse(status: 200)
    default:
      return HTTPResponse(status: 404)
    }
  }
}

@Suite("eSCL client")
struct ESCLClientTests {
  func client(_ scanner: CanonLikeScanner) -> ESCLClient {
    var config = ESCLClient.Configuration()
    config.retryDelay = .milliseconds(1)
    return ESCLClient(
      endpoint: ESCLEndpoint(host: "192.168.1.50"),
      transport: FakeTransport { await scanner.handle($0) },
      configuration: config)
  }

  @Test func waitsThroughEarly404sAndReceivesAllPages() async throws {
    let scanner = CanonLikeScanner(pages: 5)
    var pages = 0
    for try await _ in client(scanner).scan(ScanSettings(source: .feeder), capabilities: nil) { pages += 1 }
    #expect(pages == 5)
    #expect(await scanner.deletes == 0)
  }

  @Test func platenReturnsSinglePage() async throws {
    let scanner = CanonLikeScanner(pages: 3)
    var pages = 0
    for try await _ in client(scanner).scan(ScanSettings(source: .platen), capabilities: nil) { pages += 1 }
    #expect(pages == 1)
  }
}
