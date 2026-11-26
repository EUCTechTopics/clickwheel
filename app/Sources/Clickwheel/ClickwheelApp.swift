import SwiftUI

@main
struct ClickwheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Clickwheel", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 860, minHeight: 600)
                .task { await Snapshotter.runIfRequested(state) }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 940, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Choose Repository…") { state.chooseRepo() }
            }
            CommandGroup(after: .toolbar) {
                Button("Look for iPods Again") { Task { await state.scan(quiet: false) } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .windowList) {
                OpenDetailsButton()
            }
        }
        Window("Clickwheel Details", id: "details") {
            DetailsView()
                .environment(state)
        }
        .defaultSize(width: 720, height: 680)
    }
}

private struct OpenDetailsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Details & Log") { openWindow(id: "details") }
            .keyboardShortcut("i")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` there's no bundle: still behave as a regular app.
        NSApp.setActivationPolicy(.regular)
        if let a = ProcessInfo.processInfo.environment["CLICKWHEEL_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Developer aid: `CLICKWHEEL_SNAPSHOT=/some/dir open Clickwheel.app` renders every page of the
/// main window to PNGs in that directory and quits. Used to review the UI without screen recording.
@MainActor
enum Snapshotter {
    static func runIfRequested(_ state: AppState) async {
        guard let dir = ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT"] else { return }
        if let n = ProcessInfo.processInfo.environment["CLICKWHEEL_FRAMES"].flatMap(Int.init) {
            // Record the first moments after launch as numbered frames (to debug launch-time motion).
            for i in 0..<n {
                if let win = NSApp.windows.first(where: { $0.isVisible }), let view = win.contentView?.superview,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "frame%02d.png", i)))
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(for: .seconds(3))
        func shot(_ name: String, sheet: Bool = false) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
            let win = sheet ? (main.attachedSheet ?? main) : main
            guard let view = win.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        if ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO"] != nil {
            state.demoPatches = ["labels": "applied", "composers": "applied", "producers": "applied"]
            state.selected = [.labels, .composers, .producers]
            try? await Task.sleep(for: .seconds(1))
        }
        shot("main")
        guard ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO"] != nil else { NSApp.terminate(nil); return }
        state.selected = [.labels, .composers]
        state.schedulePlan()
        try? await Task.sleep(for: .seconds(1.5))
        shot("changed")
        state.stages = [.prepare, .install, .verify]
        state.stage = .install
        state.progress = 0.62
        state.busy = "Writing to your iPod"
        try? await Task.sleep(for: .seconds(0.8))
        shot("working")
        state.stages = []; state.stage = nil; state.progress = nil; state.busy = nil
        state.demoPatches = ["labels": "applied", "composers": "applied", "producers": "original"]
        state.flashed = URL(fileURLWithPath: "/tmp/demo.bin")
        try? await Task.sleep(for: .seconds(1.2))
        shot("done")
        state.flashed = nil
        NSApp.terminate(nil)
    }
}
