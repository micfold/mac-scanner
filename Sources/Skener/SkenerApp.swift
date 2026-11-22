import SwiftUI
import AppKit

@main
struct SkenerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Skener", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Skenování") {
                Button("Skenovat") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                Button("Přiskenovat do posledního dokumentu") { model.startScan(intoLast: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.documents.isEmpty)
                Button("Zastavit skenování") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Button("Protokol komunikace") { model.showLog = true }
                    .keyboardShortcut("l")
                Divider()
                Button("Uložit dávku") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(model.isBusy || model.documents.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Při spuštění přes `swift run` není aplikace zabalená – tímto se chová jako běžná aplikace.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
