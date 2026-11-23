import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacDirStatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("MacDirStat", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(state: state) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { state.chooseFolder() }
                .keyboardShortcut("o")
            Button("Scan Home Folder") { state.startScan(path: NSHomeDirectory()) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Scan Whole Disk") { state.startScan(path: "/") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Rescan") { state.rescan() }
                .keyboardShortcut("r")
                .disabled(state.result == nil)
            Button("Close Scan") { state.closeScan() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(state.result == nil)
        }
        CommandMenu("Selection") {
            Button("Open") { state.open(state.selected) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(state.selected == nil)
            Button("Reveal in Finder") { state.reveal(state.selected) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.selected == nil)
            Button("Copy Path") { state.copyPath(state.selected) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(state.selected == nil)
            Divider()
            Button("Zoom In") { state.zoomIn() }
                .keyboardShortcut("+")
                .disabled(state.selected == nil)
            Button("Zoom Out") { state.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!state.canZoomOut)
            Button("Zoom to Top") { state.zoomReset() }
                .keyboardShortcut("0")
                .disabled(!state.canZoomOut)
            Divider()
            Button("Clear Highlight") { state.highlightExt = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(state.highlightExt == nil)
            Divider()
            Button("Move to Trash…") { state.requestTrash(state.selected) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.selected?.parent == nil)
        }
    }
}
