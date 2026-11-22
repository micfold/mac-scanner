import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ESCLError: Error, LocalizedError, Equatable {
    case cannotConnect(host: String, detail: String)
    case http(status: Int, during: String)
    case feederEmpty
    case busy
    case adfProblem(String)
    case noJobLocation
    case unsupported(String)
    case jobEnded(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotConnect(let host, let detail):
            return "Nelze se připojit ke skeneru na \(host). Je tiskárna zapnutá a ve stejné síti? (\(detail))"
        case .http(let status, let during):
            return "Skener odmítl požadavek (\(during), HTTP \(status))."
        case .feederEmpty:
            return "Podavač je prázdný – vložte papíry lícem nahoru."
        case .busy:
            return "Skener je právě zaneprázdněný. Zkuste to za chvíli znovu."
        case .adfProblem(let m):
            return m
        case .noJobLocation:
            return "Skener nevrátil adresu úlohy."
        case .unsupported(let m):
            return m
        case .jobEnded(let state):
            return state == "Canceled"
                ? "Skenování bylo zrušeno na tiskárně."
                : "Skener úlohu ukončil bez stránek (\(state)). Je papír vložený správně?"
        case .cancelled:
            return "Skenování bylo zrušeno."
        }
    }
}

/// Adresa eSCL služby, typicky http://<ip>/eSCL
public struct ESCLEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int?
    public var rootPath: String
    public var tls: Bool

    public init(host: String, port: Int? = nil, rootPath: String = "eSCL", tls: Bool = false) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.rootPath = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tls = tls
    }

    public var baseURL: URL {
        var c = URLComponents()
        c.scheme = tls ? "https" : "http"
        c.host = host
        c.port = port
        c.path = rootPath.isEmpty ? "" : "/" + rootPath
        return c.url ?? URL(string: "http://invalid.local/eSCL")!
    }

    /// Location z odpovědi může být absolutní (i s jiným hostname tiskárny) nebo relativní.
    /// Bereme z ní jen cestu a skládáme ji k naší adrese – spolehlivější.
    public func resolve(location: String) -> URL? {
        let path: String
        if let u = URL(string: location), u.scheme != nil { path = u.path }
        else { path = location.hasPrefix("/") ? location : "/" + location }
        guard !path.isEmpty, path != "/" else { return nil }
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = path
        return c.url
    }
}

public final class ESCLClient: @unchecked Sendable {
    public let endpoint: ESCLEndpoint
    private let session: URLSession

    /// Kolikrát zkusit znovu, když skener odpoví 503 (zahřívá se / podává papír).
    public var busyRetries = 90
    public var busyDelay: TimeInterval = 1.0
    /// Jak dlouho nejvýše čekat na úlohu, která podle skeneru ještě běží (s).
    public var maxJobWait: TimeInterval = 180
    /// Protokol komunikace (jedna řádka na událost) – pro ladění.
    public var log: (@Sendable (String) -> Void)?

    public init(endpoint: ESCLEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 120     // NextDocument čeká, než se stránka naskenuje
            cfg.timeoutIntervalForResource = 600
            cfg.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: HTTP

    struct Response { let status: Int; let data: Data; let headers: [String: String] }

    func send(_ method: String, _ url: URL, body: Data? = nil, contentType: String? = nil,
              timeout: TimeInterval? = nil) async throws -> Response {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let timeout { req.timeoutInterval = timeout }
        let session = self.session
        let host = endpoint.host
        let box = TaskBox()
        let log = self.log
        let started = Date()
        let label = "\(method) \(url.path)"
        log?("→ \(label)")
        if let body, method == "POST", let text = String(data: body, encoding: .utf8) {
            log?("  " + text.replacingOccurrences(of: "\n", with: "\n  "))
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = session.dataTask(with: req) { data, resp, err in
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if let err {
                        log?("← \(label): chyba po \(ms) ms – \(err.localizedDescription)")
                        if (err as NSError).code == NSURLErrorCancelled { cont.resume(throwing: ESCLError.cancelled); return }
                        cont.resume(throwing: ESCLError.cannotConnect(host: host, detail: err.localizedDescription))
                        return
                    }
                    let http = resp as? HTTPURLResponse
                    var headers: [String: String] = [:]
                    for (k, v) in http?.allHeaderFields ?? [:] {
                        if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
                    }
                    let status = http?.statusCode ?? 0
                    var line = "← \(status) \(label) · \(data?.count ?? 0) B · \(ms) ms"
                    if let loc = headers["location"] { line += " · Location: \(loc)" }
                    log?(line)
                    if let log, status != 200 || !(headers["content-type"] ?? "").hasPrefix("image"),
                       let d = data, !d.isEmpty, d.count < 4000, let text = String(data: d, encoding: .utf8) {
                        log("  " + text.replacingOccurrences(of: "\n", with: "\n  "))
                    }
                    cont.resume(returning: Response(status: status, data: data ?? Data(), headers: headers))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func set(_ t: URLSessionTask) {
            lock.lock(); task = t; let c = cancelled; lock.unlock()
            if c { t.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let t = task; lock.unlock()
            t?.cancel()
        }
    }

    private func url(_ path: String) -> URL { endpoint.baseURL.appendingPathComponent(path) }

    // MARK: API

    public func capabilities() async throws -> ScannerCapabilities {
        let r = try await send("GET", url("ScannerCapabilities"), timeout: 10)
        guard r.status == 200 else { throw ESCLError.http(status: r.status, during: "zjištění schopností skeneru") }
        return try ScannerCapabilities.parse(r.data)
    }

    public func status() async throws -> ScannerStatus {
        let r = try await send("GET", url("ScannerStatus"), timeout: 10)
        guard r.status == 200 else { throw ESCLError.http(status: r.status, during: "zjištění stavu skeneru") }
        return try ScannerStatus.parse(r.data)
    }

    /// Založí úlohu a vrátí její URL.
    public func createJob(settingsXML: String) async throws -> URL {
        let body = Data(settingsXML.utf8)
        for attempt in 0..<10 {
            let r = try await send("POST", url("ScanJobs"), body: body, contentType: "text/xml", timeout: 30)
            switch r.status {
            case 200, 201:
                guard let loc = r.headers["location"], let job = endpoint.resolve(location: loc) else {
                    throw ESCLError.noJobLocation
                }
                return job
            case 409:
                throw ESCLError.feederEmpty
            case 503:
                if attempt < 9 { try await sleep(2); continue }
                throw ESCLError.busy
            default:
                throw ESCLError.http(status: r.status, during: "založení úlohy skenování")
            }
        }
        throw ESCLError.busy
    }

    /// Další stránka úlohy. `nil` = žádné další stránky.
    ///
    /// Odpověď 404 neznamená vždy konec: některé skenery (např. Canon) ji vrací i tehdy,
    /// když první stránka ještě není nasnímaná. Proto se při 404 podíváme do stavu skeneru,
    /// jestli naše úloha ještě běží, a případně počkáme.
    public func nextDocument(job: URL, received: Int = 0) async throws -> Data? {
        let u = job.appendingPathComponent("NextDocument")
        var retries = 0
        let started = Date()
        while true {
            try Task.checkCancellation()
            let r = try await send("GET", u, timeout: 120)
            switch r.status {
            case 200:
                return r.data
            case 410:
                return nil
            case 404:
                let waited = Date().timeIntervalSince(started)
                let info = try? await status().job(job)
                if let info {
                    log?("  stav úlohy: \(info.state), hotovo \(info.imagesCompleted.map(String.init) ?? "?"), k přenosu \(info.imagesToTransfer.map(String.init) ?? "?")")
                    if info.isRunning && waited < maxJobWait { try await sleep(1); continue }
                    if !info.isRunning && info.state != "Completed" && received == 0 {
                        throw ESCLError.jobEnded(info.state)
                    }
                    return nil
                }
                // Skener o úlohách nic neříká – na první stránku chvíli počkáme.
                if received == 0 && waited < 30 { try await sleep(1); continue }
                return nil
            case 503:
                retries += 1
                if retries > busyRetries { throw ESCLError.busy }
                try await sleep(busyDelay)
            case 409:
                throw ESCLError.feederEmpty
            default:
                throw ESCLError.http(status: r.status, during: "stahování stránky")
            }
        }
    }

    public func cancel(job: URL) async {
        _ = try? await send("DELETE", job, timeout: 5)
    }

    /// Celý sken: založí úlohu a stahuje stránky, dokud nějaké jsou.
    /// `onPage` dostane JPEG data a pořadové číslo stránky v rámci úlohy (od 0).
    @discardableResult
    public func scan(settings: ScanSettings, capabilities caps: ScannerCapabilities?,
                     onPage: @escaping @Sendable (Data, Int) async -> Void) async throws -> Int {
        if let caps {
            if settings.source == .feeder && !caps.hasFeeder {
                throw ESCLError.unsupported("Tento skener nemá podavač.")
            }
            if let ic = caps.caps(for: settings.source, duplex: settings.effectiveDuplex),
               !ic.documentFormats.isEmpty, !ic.documentFormats.contains("image/jpeg") {
                throw ESCLError.unsupported("Skener neumí posílat stránky jako JPEG.")
            }
        }
        if settings.source == .feeder, let st = try? await status() {
            if let problem = st.adfProblem { throw ESCLError.adfProblem(problem) }
            if st.adfLoaded == false { throw ESCLError.feederEmpty }
        }

        let xml = settings.xml(version: caps?.version ?? "2.0",
                               caps: caps?.caps(for: settings.source, duplex: settings.effectiveDuplex))
        let job = try await createJob(settingsXML: xml)
        var count = 0
        do {
            while let page = try await nextDocument(job: job, received: count) {
                await onPage(page, count)
                count += 1
                if settings.source == .platen { break }   // ze skla je vždy jen jedna stránka
            }
            if count == 0 { await cancel(job: job) }   // ať skener nezůstane viset ve „Skenování…“
        } catch {
            await cancel(job: job)
            if error is CancellationError { throw ESCLError.cancelled }
            throw error
        }
        return count
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
