import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The main window: one screen per iPod, like Finder's device page. The iPod and what's on it at the
// top, the changes as switches with a live preview, and one Apply button. Applying asks for the Mac
// password once, reads the iPod, writes only what changes and reads it back. Progress and the result
// show in place. The iPod's firmware is kept in ~/Library/Application Support/Clickwheel.
// Everything technical (bytes, checksums, partitions, the log, rollback) lives in the Details window.

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        Group {
            switch state.phase {
            case .searching: ProgressView("Looking for your iPod…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connect: ConnectScreen()
            case .unsupported(let why): UnsupportedScreen(reason: why)
            case .ready: DeviceScreen()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: state.phase)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.device != nil {
                    Button("Eject", systemImage: "eject") { Task { await state.eject() } }
                        .disabled(state.working)
                        .help("Eject the iPod")
                }
                Button("Details", systemImage: "info.circle") { openWindow(id: "details") }
                    .help("Technical details, log and expert tools")
            }
        }
        .navigationTitle("Clickwheel")
        .alert(item: $state.alert) { a in
            if a.fullDiskAccess {
                Alert(title: Text(a.title), message: Text(a.message),
                      primaryButton: .default(Text("Open Privacy Settings")) { AppState.openFullDiskAccessSettings() },
                      secondaryButton: .cancel(Text("Later")))
            } else {
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

/// A centred column with a big symbol, a title and a short explanation.
private struct Hero<Content: View>: View {
    var symbol: String
    var tint: Color = .accentColor
    var title: String
    var text: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(tint)
                    .frame(height: 70)
                Text(title).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                Text(text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 40)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - No iPod / not supported

struct ConnectScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Hero(symbol: "cable.connector", title: "Connect your iPod",
             text: "Plug your click-wheel iPod into this Mac with its cable. Clickwheel finds it by itself.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Works with").font(.headline)
                ForEach(IPodModel.allCases) { m in
                    Label(m.displayName, systemImage: "checkmark").foregroundStyle(.secondary)
                }
                Text("The iPod must be set up for a Mac (not Windows).").font(.callout).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .padding(.top, 10)
        }
    }
}

struct UnsupportedScreen: View {
    @Environment(AppState.self) private var state
    var reason: String
    var body: some View {
        Hero(symbol: "exclamationmark.triangle", tint: Theme.amber, title: "Clickwheel can't change this iPod",
             text: LocalizedStringKey(reason)) {
            if state.device != nil {
                Button("Eject iPod", systemImage: "eject") { Task { await state.eject() } }
                    .controlSize(.large)
            }
        }
    }
}

// MARK: - The iPod

struct DeviceScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        DeviceHeader()
                        if state.hasPending { PendingBanner() }
                        ChangeList()
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                ActionBar()
            }
            Divider()
            PreviewColumn()
                .frame(width: 280)
        }
    }
}

/// The iPod's name, model and what's on it now.
struct DeviceHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "ipod")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 76)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(state.device?.volumeName ?? "iPod").font(.title.weight(.semibold)).lineLimit(1)
                Text(facts).foregroundStyle(.secondary)
                status
            }
        }
    }

    private var facts: String {
        guard let d = state.device else { return "" }
        var parts = [d.model?.displayName ?? "iPod"]
        if let c = d.capacity { parts.append(ByteCountFormatter.string(fromByteCount: Int64(c), countStyle: .file)) }
        if let v = d.firmwareVersion { parts.append("Software \(v)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if state.checking || state.stage == .read {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking what's on your iPod…")
            }
            .font(.callout).foregroundStyle(.secondary)
        } else if state.deviceState == nil {
            HStack(spacing: 6) {
                Text("Clickwheel hasn't read this iPod yet.")
                Button("Check") { Task { await state.readDeviceState() } }
                    .buttonStyle(.link)
                    .disabled(state.working)
                    .help("Reads the iPod (asks for your Mac password). Changes nothing.")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// An earlier install didn't complete: the next Apply finishes it.
struct PendingBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber).font(.title3)
            Text("The last install didn't finish. Keep the iPod connected and press **Apply** to complete it.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.amber.opacity(0.35), lineWidth: 0.5))
    }
}

/// The three changes as switches, each saying whether applying adds or removes it.
struct ChangeList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.patchIDs.enumerated()), id: \.element) { i, p in
                if i > 0 { Divider().padding(.leading, 60) }
                ChangeRow(patch: p)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .disabled(state.working || state.hasPending)
    }
}

struct ChangeRow: View {
    @Environment(AppState.self) private var state
    var patch: PatchID

    var body: some View {
        let on = state.selected.contains(patch)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: patch.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Color.white : .secondary)
                .frame(width: 32, height: 32)
                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(patch.plainTitle).font(.headline)
                Text(state.isCustom(patch)
                     ? "Your iPod has its own picture here, put on with another tool (such as iPodWizard). Clickwheel leaves it as it is."
                     : patch.plainBlurb)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if on && (patch.takesPicture || state.ownPicture.contains(patch)) {
                    HStack(spacing: 8) {
                        Text(state.customPictures[patch].map { "New picture: \($0.lastPathComponent)" } ?? "Your picture is on the iPod.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Choose Another…") { choose() }.controlSize(.small)
                    }
                } else if patch.ownPictureOptional(on: state.model) {
                    Text("Option-click the switch to use your own \(patch.pictureSize.width)×\(patch.pictureSize.height) BMP instead.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { on },
                set: { v in
                    let option = NSEvent.modifierFlags.contains(.option)
                    if v && (patch.takesPicture || (option && patch.ownPictureOptional(on: state.model))) {
                        choose()       // on = a picture was picked; cancelling leaves it off
                        return
                    }
                    withAnimation(.snappy(duration: 0.2)) {
                        if v { state.selected.insert(patch) } else { state.selected.remove(patch) }
                        state.customPictures[patch] = nil
                        state.ownPicture.remove(patch)
                        state.flashed = nil
                    }
                    state.schedulePlan()
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(state.isCustom(patch))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Ask for a BMP of the right size; on success the change is switched on with that file.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let size = patch.pictureSize
        panel.message = "Choose a \(size.width)×\(size.height) BMP picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let (w, h) = bmpSize(url), (w, h) == (size.width, size.height) else {
            state.alert = AppState.AlertInfo(title: "This picture doesn't fit",
                                    message: "Choose a BMP of exactly \(size.width)×\(size.height) pixels (16- or 24-bit).")
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            state.customPictures[patch] = url
            if !patch.takesPicture { state.ownPicture.insert(patch) }
            state.selected.insert(patch)
            state.flashed = nil
        }
        state.schedulePlan()
    }

    /// Width and height from a BMP header, or nil when it isn't a BMP.
    private func bmpSize(_ url: URL) -> (Int, Int)? {
        guard let d = try? Data(contentsOf: url), d.count >= 26, d[0] == 0x42, d[1] == 0x4D else { return nil }
        func i32(_ o: Int) -> Int32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
        return (Int(i32(18)), Int(abs(i32(22))))
    }
}

// MARK: - Apply, progress and result (the bar at the bottom)

struct ActionBar: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if state.working {
                    progress
                } else if state.flashed != nil && state.selectionIsInstalled {
                    success
                } else {
                    idle
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(minHeight: 64)
            .animation(.snappy, value: state.working)
        }
        .background(.bar)
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button(state.selected.isEmpty ? "Restore Original Menus" : "Apply") { Task { await state.apply() } }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        let name = state.device?.volumeName.map { "“\($0)”" } ?? "your iPod"
        return state.selected.isEmpty ? "Put the original menus back on \(name)?" : "Change the menus on \(name)?"
    }
    private var confirmMessage: String {
        "macOS asks for your Mac password. Keep the iPod connected until Clickwheel is done. Your music isn't touched."
    }

    // Idle: just the Apply button.
    private var idle: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                confirm = true
            } label: {
                Text("Apply").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canApply)
        }
    }

    // Working: the stages as a row, the current one with a progress bar.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(state.stages.enumerated()), id: \.element) { i, s in
                    let cur = state.stages.firstIndex(of: state.stage ?? s) ?? 0
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                    HStack(spacing: 5) {
                        if i < cur {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.phosphor)
                        } else if i == cur {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                        Text(s.rawValue)
                            .fontWeight(i == cur ? .semibold : .regular)
                            .foregroundStyle(i <= cur ? .primary : .secondary)
                    }
                }
                Spacer()
            }
            .font(.callout)
            ProgressView(value: state.progress ?? 0)
                .opacity(state.progress == nil ? 0.3 : 1)
            Text(state.busy == "Waiting for your Mac password" ? "Type your Mac password in the dialog." : (state.busy.map { $0 + "…" } ?? " ") + "  Keep the iPod connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // Done: verified. Ejecting lets the iPod restart by itself with the new menus.
    private var success: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.phosphor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Done. Your iPod has the new menus.").font(.headline)
                Text("Eject it to finish. It then restarts by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Eject", systemImage: "eject.fill") { Task { await state.eject() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Details window (technical; for people who want to see exactly what happens)

struct DetailsView: View {
    var body: some View {
        TabView {
            TechnicalView().tabItem { Text("Details") }
            ConsolePage().tabItem { Text("Log") }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

struct TechnicalView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "iPod", symbol: "ipod") {
                    if let d = state.device {
                        SpecRow(key: "model", value: d.model?.displayName ?? "not supported")
                        SpecRow(key: "board", value: d.board ?? "— (SysInfo not readable)")
                        SpecRow(key: "model no.", value: d.modelNumber ?? "—")
                        SpecRow(key: "firmware", value: [d.firmwareVersion, d.buildVersion.map { "build " + $0 }].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                        SpecRow(key: "partition", value: "/dev/\(d.partition) · Apple_MDFW · \(d.partitionSize >> 20) MiB")
                        SpecRow(key: "volume", value: d.mountPoint ?? "not mounted")
                    } else {
                        Text("No iPod connected.").foregroundStyle(.secondary)
                    }
                }
                if state.device?.model != nil { DeviceStateCard() }
                Card(title: "Firmware on this Mac", symbol: "externaldrive") {
                    if let c = state.check, c.ok, let u = state.current {
                        SpecRow(key: "file", value: u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        SpecRow(key: "sha256", value: c.sha256 ?? "?")
                        if let i = state.currentInfo {
                            SpecRow(key: "from", value: (i.source == "write" ? "written and verified" : "read from the iPod") + " · " + i.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        SpecRow(key: "changes in it", value: state.patchIDs.filter { c.patches?[$0.rawValue]?.state == "applied" }.map(\.rawValue).joined(separator: " + ").ifEmpty("none"))
                        if let stock = c.osos?.stock {
                            SpecRow(key: "osos vs Apple original", value: stock ? "identical" : "differs", valueColor: stock ? Theme.phosphor : .secondary)
                        }
                        HStack {
                            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Spacer()
                        }
                        .controlSize(.small)
                    } else {
                        Text("Nothing yet. Clickwheel reads the iPod when you press Apply or Check, and keeps its firmware here.").foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let c = state.check, let plan = state.plan, let changes = plan.changes {
                    Card(title: "Planned change · \(state.selectionFlags.joined(separator: " "))", symbol: "number") {
                        PartitionMap(size: c.part_size ?? state.model?.partitionSize ?? 1, images: c.images ?? [],
                                     marks: (plan.sectors ?? []).filter { $0 != (c.checksum_offset ?? 0) / 512 * 512 },
                                     checksumOffset: c.checksum_offset)
                        Text("\(changes.count) bytes · \(plan.sectors?.count ?? 0) sectors (compared with what's on the iPod)")
                            .font(Theme.monoSmall).foregroundStyle(.secondary)
                        if !changes.isEmpty { HexDiff(changes: changes) }
                        Divider()
                        SpecRow(key: "osos checksum @ \(hex(c.checksum_offset ?? 0x421C, width: 4))",
                                value: "\(hex32(c.osos?.checksum ?? 0)) → \(hex32(plan.new_checksum ?? 0))", valueColor: Theme.phosphor)
                        if let s = plan.result_stock {
                            SpecRow(key: "result vs Apple stock", value: s ? "identical" : "differs", valueColor: s ? Theme.phosphor : .secondary)
                        }
                    }
                }
                Card(title: "If something goes wrong", symbol: "lifepreserver") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("**Undo:** switch everything off in the main window and press Apply. That puts Apple's original bytes back.", systemImage: "arrow.uturn.backward")
                        Label("**An install didn't finish:** keep the iPod connected and press Apply again; Clickwheel completes it.", systemImage: "arrow.clockwise")
                        Label("**Doesn't start:** hold Menu + Select to reset; when the Apple logo appears, hold Select + Play until “Do not disconnect” (disk mode). Connect it and press Apply (or switch everything off and press Apply).", systemImage: "power")
                        Label("**Last resort:** restore in Finder. That reinstalls Apple's software and erases the music.", systemImage: "exclamationmark.triangle")
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - Log

struct ConsolePage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(state.log.count) lines · also in ~/Library/Logs/Clickwheel.log").font(Theme.monoSmall).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    let text = state.log.map { "[\($0.time.formatted(date: .omitted, time: .standard))] \($0.kind == .cmd ? "$ " : "")\($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear", systemImage: "trash") { state.log.removeAll() }
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.log) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(l.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                                    .foregroundStyle(.white.opacity(0.3))
                                Text(prefix(l.kind)).foregroundStyle(color(l.kind).opacity(0.8))
                                Text(l.text).foregroundStyle(color(l.kind)).textSelection(.enabled)
                            }
                            .id(l.id)
                        }
                    }
                    .font(Theme.monoSmall)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(red: 0.05, green: 0.07, blue: 0.06))
                .onChange(of: state.log.count) { _, _ in
                    if let last = state.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func prefix(_ k: LogLine.Kind) -> String {
        switch k { case .cmd: return "$"; case .ok: return "✓"; case .err: return "✗"; case .info: return "·"; case .out: return " " }
    }
    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .cmd: return .white
        case .ok: return Theme.phosphorOnDark
        case .err: return Color(red: 1, green: 0.42, blue: 0.4)
        case .info: return .white.opacity(0.55)
        case .out: return Theme.phosphorOnDark.opacity(0.75)
        }
    }
}
