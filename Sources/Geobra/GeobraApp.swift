import AppKit
import SwiftUI

@main
struct GeobraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup("Geobra") {
            WorkspaceView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(.dark)
                .onOpenURL { store.openURL($0) }
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Geographic Files…", action: store.chooseImport)
                    .keyboardShortcut("i", modifiers: .command)
                Button("Open Workspace…", action: store.chooseWorkspace)
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save Workspace As…", action: store.saveWorkspaceAs)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export GeoJSON…", action: store.exportGeoJSON)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Places") {
                Button("New Folder", action: store.addFolder)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Show Selection on Globe", action: store.focusSelection)
                    .keyboardShortcut("j", modifiers: .command)
                Button("Reset Globe", action: store.resetGlobe)
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
