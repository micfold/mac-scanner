import AppFeature
import AppKit
import SwiftUI

@main
struct SkenerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel.live()

  var body: some Scene {
    Window("Skener", id: "main") {
      RootView(model: model)
        .frame(minWidth: 1020, minHeight: 660)
        .task { await model.run() }
    }
    .defaultSize(width: 1280, height: 820)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Zařízení") {
        Button("Skenovat") {
          model.section = .scan
          model.scan.scan()
        }
        .keyboardShortcut("r")
        Button("Přiskenovat do posledního dokumentu") {
          model.section = .scan
          model.scan.scan(intoLast: true)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Zastavit skenování") { model.scan.cancelScan() }
          .keyboardShortcut(".")
        Divider()
        Button("Tisknout…") {
          model.section = .print
          model.print.chooseFiles()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Protokol komunikace") { model.showLog = true }
          .keyboardShortcut("l")
      }
    }

    MenuBarExtra("Skener", systemImage: "printer") {
      MenuBarView(model: model)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Lets `swift run Skener` behave like a regular app (no bundle needed).
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
