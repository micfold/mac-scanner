# Architecture

Skener is a small macOS app, so it uses the lightest structure that still keeps
protocol code, app state and UI apart and testable: **feature modules with
`@Observable` models and protocol-based services** (sometimes called "MV" —
the pattern Apple's own SwiftUI samples use), on **Swift 6 strict concurrency**.

```
┌──────────────────────────── Skener (executable) ────────────────────────────┐
│  @main SkenerApp — windows, menu bar extra, settings, commands              │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │ AppModel.live()
┌──────────────────────────── AppFeature (macOS) ─────────────────────────────┐
│  App/        AppModel (composition root), RootView, Settings, MenuBarView   │
│  Device/     DeviceSession (shared device state + polling), Discovery,      │
│              Preferences, LogStore                                          │
│  Overview/   dashboard           Jobs/   job queue                          │
│  Scan/       ScanModel + views, PageImaging, ScanExporter (PDF + OCR)        │
│  Print/      PrintModel + views, PrintComposer (images → PDF, letterhead)   │
│  Services/   PrinterService / ScannerService protocols, live + preview impls│
│  Shared/     components, user-facing text                                   │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │ protocols
┌──────────────────────────── PrinterKit (Foundation) ────────────────────────┐
│  Transport/  HTTPTransport protocol, URLSession impl, logging decorator     │
│  IPP/        message codec, IPPClient, PrinterInfo / PrintTicket models     │
│  ESCL/       ESCLClient, capabilities / status / settings models            │
│  Batch/      BatchSplitter, FileNamer                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Rules of thumb

- **PrinterKit knows nothing about UI.** Value types, `Sendable`, no strings for
  people. It builds on macOS and Linux and is where most tests live.
- **Clients take an `HTTPTransport`.** Tests inject a fake transport (see
  `CanonLikeScanner` in the tests) instead of mocking the client.
- **Features talk to services, not clients.** `PrinterService` and
  `ScannerService` are protocols; `ServiceFactory.live` wires IPP/eSCL,
  `SampleDevice.factory` gives canned data for previews, screenshots and tests.
- **One `@Observable @MainActor` model per feature**, owned by `AppModel`.
  Views hold no logic beyond layout and bindings.
- **Heavy work leaves the main actor explicitly** (`Task.detached`) and only
  `Sendable` values cross: JPEG `Data`, `PrintDocument`, `Thumbnail`.
- **All user-facing text sits in `Shared/Text.swift`** and next to its view,
  ready to move into a String Catalog.

## Protocols

| Need | Protocol | Where |
|---|---|---|
| State, supplies, trays, capabilities | IPP `Get-Printer-Attributes` | `IPPClient.printerInfo()` |
| Print | IPP `Print-Job` (PDF), or `lp` via the macOS queue when PDF is not accepted | `LivePrinter` |
| Queue | IPP `Get-Jobs`, `Cancel-Job` | `IPPClient.jobs()` |
| Find the printer | IPP `Identify-Printer` | `IPPClient.identify()` |
| Scan | eSCL `ScanJobs` / `NextDocument` | `ESCLClient.scan()` |
| Discovery | Bonjour `_ipp._tcp`, `_uscan._tcp` | `Discovery` |

Canon firmware answers `NextDocument` with 404 until the first page is
captured; the client polls the job state before giving up
(`ESCLClient.nextDocument`).

## Tooling

| | |
|---|---|
| Format / lint | `swift format` with `.swift-format` (CI fails on violations) |
| Tests | Swift Testing — `swift test` (PrinterKit on Linux and macOS, AppFeature on macOS) |
| Screenshots | `swift run snapshots build/snapshots` renders every screen with sample data + `demo.gif` |
| CI | `.github/workflows/ci.yml`: Lint · Test (Linux) · Build & test (macOS) |
| Release | push a `v*` tag → `.github/workflows/release.yml` publishes `Skener-vX.zip` |
| Branch protection | `.github/rulesets/main.json`, applied with `scripts/setup-github.sh` |
