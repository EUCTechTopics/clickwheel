import SwiftUI

@main
struct ClickwheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Clickwheel", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1060, minHeight: 680)
                .task { await Snapshotter.runIfRequested(state) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Choose Repository…") { state.chooseRepo() }
            }
            CommandGroup(after: .toolbar) {
                Button("Rescan for iPods") { Task { await state.scan(quiet: false) } }
                    .keyboardShortcut("r")
            }
        }
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

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var inspector = true

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                switch state.step {
                case .device: DevicePage()
                case .backup: BackupPage()
                case .patches: PatchesPage()
                case .flash: FlashPage()
                case .restore: RestorePage()
                case .console: ConsolePage()
                }
            }
            .inspector(isPresented: $inspector) {
                PreviewPanel()
                    .inspectorColumnWidth(min: 250, ideal: 270, max: 320)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let b = state.busy {
                    HStack(spacing: 8) {
                        BusyLabel(text: b + "…")
                        if state.terminalTask != nil {
                            Button("Stop Waiting") { state.stopWaiting() }
                                .help("Stop waiting for the Terminal window; the command there keeps running")
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Rescan", systemImage: "arrow.triangle.2.circlepath") { Task { await state.scan(quiet: false) } }
                    .help("Look for connected iPods again")
                Button("Preview", systemImage: "sidebar.trailing") { inspector.toggle() }
                    .help("Show or hide the iPod preview")
            }
        }
        .navigationTitle("Clickwheel")
        .navigationSubtitle(state.device.map { "\($0.model?.displayName ?? "unknown iPod") · /dev/\($0.partition)" } ?? "no iPod connected")
        .sheet(item: $state.terminal) { s in
            TerminalPanel(session: s).environment(state)
                .interactiveDismissDisabled()
        }
        .alert(item: $state.alert) { a in
            if a.fullDiskAccess {
                Alert(title: Text(a.title), message: Text(a.message),
                      primaryButton: .default(Text("Open Full Disk Access Settings")) { AppState.openFullDiskAccessSettings() },
                      secondaryButton: .cancel(Text("Later")))
            } else {
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            List(selection: $state.step) {
                Section("Workflow") {
                    ForEach([Step.device, .backup, .patches, .flash]) { row($0) }
                }
                Section("Tools") {
                    ForEach([Step.restore, .console]) { row($0) }
                }
            }
            .listStyle(.sidebar)
            footer
        }
    }

    private func row(_ s: Step) -> some View {
        let st = state.status(s)
        return HStack(spacing: 10) {
            Text(s.number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .leading)
            Label(s.title, systemImage: s.symbol)
            Spacer()
            LED(color: st.color, pulsing: st == .ready && state.busy != nil)
                .help(st.label)
        }
        .tag(s)
    }

    /// A tiny "system monitor" in the sidebar footer.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            HStack(spacing: 6) {
                LED(color: state.device == nil ? .secondary.opacity(0.4) : (state.model == nil ? .red : Theme.phosphor),
                    pulsing: state.device == nil)
                Text(state.device == nil ? "NO DEVICE" : (state.device?.board ?? "iPod").uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            Group {
                Text("dev  " + (state.device.map { "/dev/" + $0.partition } ?? "—"))
                Text("fw   " + (state.device?.firmwareVersion ?? "—"))
                Text("osos " + (state.check?.osos.map { hex($0.length) } ?? "—"))
                Text("sum  " + (state.check?.osos.map { hex32($0.checksum) } ?? "—"))
                Text("on   " + (state.installed.map { $0.patches.map { String($0.prefix(3)) }.joined(separator: "+") } ?? "—"))
                    .foregroundStyle(state.installed == nil ? Color.secondary : Theme.phosphor)
            }
            .font(Theme.monoTiny)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// Developer aid: `CLICKWHEEL_SNAPSHOT=/some/dir open Clickwheel.app` renders every page of the
/// main window to PNGs in that directory and quits. Used to review the UI without screen recording.
@MainActor
enum Snapshotter {
    static func runIfRequested(_ state: AppState) async {
        guard let dir = ProcessInfo.processInfo.environment["CLICKWHEEL_SNAPSHOT"] else { return }
        try? await Task.sleep(for: .seconds(3))
        func shot(_ name: String, sheet: Bool = false) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
            let win = sheet ? (main.attachedSheet ?? main) : main
            guard let view = win.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        for step in Step.allCases {
            state.step = step
            try? await Task.sleep(for: .seconds(1.2))
            shot(step.rawValue)
        }
        // extra states (demo mode only): after a write, and the Terminal hand-off panel
        if ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO"] != nil {
            state.built = state.plan
            state.flashed = URL(fileURLWithPath: "/tmp/demo.bin")
            state.step = .flash
            try? await Task.sleep(for: .seconds(1.2))
            shot("flash_done")
            var t = AppState.TerminalSession(title: "Backing up firmware", command: "sudo scripts/backup_fw_photo.sh disk4s2")
            t.output = "Unmount of all volumes on disk4 was successful\nReading /dev/rdisk4s2 -> firmware/ipodphoto_fw_backup.bin\n32+0 records in\n32+0 records out\n33554432 bytes transferred in 9.8 secs"
            state.terminal = t
            try? await Task.sleep(for: .seconds(1.5))
            shot("terminal", sheet: true)
        }
        NSApp.terminate(nil)
    }
}
