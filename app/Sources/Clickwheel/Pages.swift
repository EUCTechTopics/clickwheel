import SwiftUI

private struct Page<Content: View>: View {
    var step: Step
    var subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(step: step, subtitle: subtitle)
                content
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 01 Device

struct DevicePage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Page(step: .device, subtitle: "Read-only. Finds the iPod's firmware partition and identifies the model.") {
            if let d = state.device {
                Card(title: "Connected", symbol: "cable.connector") {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: "ipod")
                            .font(.system(size: 54, weight: .thin))
                            .foregroundStyle(.secondary)
                            .frame(width: 70)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.model?.displayName ?? "Unrecognised iPod").font(.title2.weight(.semibold))
                            SpecRow(key: "board", value: d.board ?? "— (SysInfo not readable)")
                            SpecRow(key: "model no.", value: d.modelNumber ?? "—")
                            SpecRow(key: "firmware", value: [d.firmwareVersion, d.buildVersion.map { "build " + $0 }].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                            SpecRow(key: "partition", value: "/dev/\(d.partition) · Apple_MDFW · \(hex(d.partitionSize, width: 7)) B")
                            SpecRow(key: "volume", value: d.mountPoint ?? "not mounted")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Eject", systemImage: "eject") { Task { await state.eject() } }
                    }
                }
                verdict(d)
            } else {
                Card {
                    VStack(spacing: 10) {
                        LED(color: .accentColor, pulsing: true)
                        Text("Waiting for an iPod…").font(.title3.weight(.medium))
                        Text("Connect a Mac-formatted click-wheel iPod. Clickwheel polls `diskutil` every 3 seconds.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            }
            Card(title: "Supported", symbol: "checklist") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("MODEL"); Text("BOARD"); Text("FIRMWARE"); Text("STATUS")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                    ForEach(IPodModel.allCases) { m in
                        GridRow {
                            HStack(spacing: 6) {
                                if state.model == m { LED(color: Theme.phosphor) } else { Circle().fill(.clear).frame(width: 8) }
                                Text(m.displayName)
                            }
                            Text(m.board).font(Theme.monoSmall)
                            Text(m.firmware).font(Theme.monoSmall)
                            m.deviceTested ? Badge(text: "tested on device", color: Theme.phosphor) : Badge(text: "static analysis", color: Theme.amber)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func verdict(_ d: Device) -> some View {
        if d.model == nil {
            Callout(kind: .danger, text: "This iPod isn't a supported model (or its data volume isn't mounted so SysInfo can't be read). The patches change bytes at exact firmware offsets, so Clickwheel stops here. Mount the iPod in Finder and it will look again.")
        } else if d.firmwareMatches == false {
            Callout(kind: .danger, text: "This iPod runs a different firmware version than the one the patches were made for (\(d.model!.firmware)). Clickwheel stops here.")
        } else {
            Callout(kind: .ok, text: "Supported model. Next: make a verified backup of the firmware.")
        }
        if d.model != nil && d.firmwareMatches != false { NextButton(to: .backup) }
    }
}

struct NextButton: View {
    @Environment(AppState.self) private var state
    var to: Step
    var body: some View {
        HStack {
            Spacer()
            Button { state.step = to } label: {
                HStack(spacing: 6) { Text("Continue to \(to.title)"); Image(systemName: "arrow.right") }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - 02 Backup

struct BackupPage: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        @Bindable var state = state
        Page(step: .backup, subtitle: "Reads the firmware partition twice and compares the hashes. Never writes to the iPod.") {
            if let model = state.model, let d = state.device {
                if let b = state.backup {
                    Card(title: "Backup on disk", symbol: "externaldrive") {
                        SpecRow(key: "file", value: "firmware/" + b.url.lastPathComponent)
                        SpecRow(key: "sha256", value: b.sha256)
                        SpecRow(key: "integrity", value: b.verified ? "matches .sha256" : "DOES NOT MATCH .sha256",
                                valueColor: b.verified ? Theme.phosphor : .red)
                        SpecRow(key: "made", value: b.modified.formatted(date: .abbreviated, time: .shortened))
                        SpecRow(key: "from iPod", value: b.originSerial.map { $0 == d.serial ? "this one (serial \($0))" : "another iPod (serial \($0))" } ?? "unknown",
                                valueColor: state.backupMatchesDevice == false ? .red : .primary)
                    }
                    if state.backupMatchesDevice == false {
                        Callout(kind: .danger, text: "This backup was made from a different iPod. Move it out of `firmware/` (don't delete it) and make a new backup of this one.")
                    } else if state.backupMatchesDevice == nil {
                        Toggle(isOn: $state.backupConfirmed) {
                            Text("I'm sure this backup was made from **this** iPod")
                        }
                        .toggleStyle(.checkbox)
                    }
                    if !b.verified {
                        Callout(kind: .danger, text: "The backup doesn't match its checksum file. Don't use it.")
                    }
                    if state.backupUsable { NextButton(to: .patches) }
                } else {
                    Card(title: "No backup yet", symbol: "externaldrive.badge.plus") {
                        Text("Clickwheel opens a Terminal window that runs `sudo scripts/\(model.backupCommand(part: d.partition)[0].split(separator: "/").last!) \(d.partition)`. Type your Mac password there; Clickwheel never sees it and picks up the result automatically.")
                            .fixedSize(horizontal: false, vertical: true)
                        SpecRow(key: "reads", value: "/dev/r\(d.partition) (\(model.partitionSize.formatted()) bytes), twice")
                        SpecRow(key: "writes", value: "firmware/\(model.backupFile) + .sha256 (on this Mac)")
                        HStack {
                            Spacer()
                            Button {
                                confirm = true
                            } label: {
                                Label("Back Up Firmware…", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.busy != nil)
                        }
                    }
                    Callout(kind: .info, text: "The iPod is unmounted during the backup (it disappears from Finder). That's expected.")
                }
            } else {
                Callout(kind: .info, text: "Connect a supported iPod first.")
            }
        }
        .confirmationDialog("Back up the firmware?", isPresented: $confirm) {
            Button("Back Up") { Task { await state.runBackup() } }
        } message: {
            Text("This only reads from the iPod. A Terminal window opens and asks for your Mac password.")
        }
    }
}

// MARK: - 03 Patches

struct PatchesPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Page(step: .patches, subtitle: "Builds a patched copy on your Mac. The iPod isn't touched in this step.") {
            if !state.backupUsable {
                Callout(kind: .info, text: "Make (or confirm) a verified backup of this iPod first. The patches are checked against it.")
            } else if let c = state.check {
                InstalledBadge()
                if c.patchable == false {
                    Callout(kind: .danger, text: "**Not patchable.** At least one patch location in your firmware doesn't contain the expected bytes, so this isn't the supported build. Clickwheel won't build anything.")
                }
                Card(title: "Patches", symbol: "hammer") {
                    VStack(spacing: 10) {
                        ForEach(PatchID.allCases) { p in
                            patchRow(p, state: c.patches?[p.rawValue]?.state ?? "?")
                            if p != PatchID.allCases.last { Divider() }
                        }
                    }
                }
                if let plan = state.plan, let changes = plan.changes {
                    Card(title: "Partition map", symbol: "memorychip") {
                        PartitionMap(size: c.part_size ?? state.model?.partitionSize ?? 1, images: c.images ?? [],
                                     marks: (plan.sectors ?? []).filter { $0 != (c.checksum_offset ?? 0) / 512 * 512 },
                                     checksumOffset: c.checksum_offset)
                    }
                    Card(title: "Diff · \(changes.count) bytes · \(plan.sectors?.count ?? 0) sectors", symbol: "number") {
                        HexDiff(changes: changes)
                        Divider()
                        SpecRow(key: "osos checksum @ \(hex(c.checksum_offset ?? 0x421C, width: 4))",
                                value: "\(hex32(c.osos?.checksum ?? 0)) → \(hex32(plan.new_checksum ?? 0))", valueColor: Theme.phosphor)
                        if let stock = c.osos?.stock {
                            SpecRow(key: "osos vs Apple stock", value: stock ? "identical" : "differs", valueColor: stock ? Theme.phosphor : Theme.amber)
                        }
                    }
                }
                if let b = state.built {
                    Callout(kind: .ok, text: "Built **\(URL(fileURLWithPath: b.output ?? "").lastPathComponent)** · sha256 `\(String((b.output_sha256 ?? "").prefix(16)))…`. Next: Flash.")
                    NextButton(to: .flash)
                }
                HStack {
                    Button("Re-check", systemImage: "arrow.clockwise") { Task { await state.runCheck() } }
                    Spacer()
                    Button {
                        Task { await state.build() }
                    } label: {
                        Label("Build Patched Copy", systemImage: "hammer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selected.isEmpty || c.patchable != true || state.busy != nil)
                }
            } else {
                BusyLabel(text: "running patch.py --check…")
            }
        }
    }

    private func patchRow(_ p: PatchID, state s: String) -> some View {
        let on = Binding(get: { state.selected.contains(p) }, set: { v in
            if v { state.selected.insert(p) } else { state.selected.remove(p) }
            state.schedulePlan()
        })
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(p.title).font(.headline)
                    Text(p.flag).font(Theme.monoTiny).foregroundStyle(.tertiary)
                }
                Text(p.blurb).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: s == "original" ? "stock bytes" : s == "applied" ? "already applied" : s, color: s == "original" ? .secondary : s == "applied" ? Theme.phosphor : .red)
                .help("State of these bytes in your backup")
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden().disabled(s == "mismatch")
        }
    }
}

// MARK: - 04 Flash

struct FlashPage: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        Page(step: .flash, subtitle: "The one step that changes the iPod. Writes only what differs, then reads it back.") {
            if let b = state.built, let model = state.model, let d = state.device {
                Card(title: state.flashed != nil ? "Written to iPod" : "Ready to write", symbol: state.flashed != nil ? "checkmark.seal" : "bolt.horizontal") {
                    SpecRow(key: "image", value: b.output.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                    SpecRow(key: "patches", value: (b.applied ?? []).joined(separator: " + "))
                    SpecRow(key: "target", value: "/dev/r\(d.partition)")
                    SpecRow(key: "sectors", value: (b.sectors ?? []).map { hex($0) }.joined(separator: " "))
                    SpecRow(key: "script", value: model.writeCommand(part: d.partition, image: "…")[0])
                }
                recovery
                if state.flashed != nil {
                    Callout(kind: .ok, text: "**Written and verified.** The new firmware starts after a reboot.")
                    TestChecklist()
                } else {
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            confirm = true
                        } label: {
                            Label("Write to iPod…", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(state.busy != nil || !state.backupUsable)
                    }
                }
            } else {
                InstalledBadge()
                Callout(kind: .info, text: "Build a patched copy first (step 03).")
            }
        }
        .confirmationDialog("Write the patched firmware to the iPod?", isPresented: $confirm) {
            Button("Write Firmware", role: .destructive) { Task { await state.runFlash() } }
        } message: {
            Text("A Terminal window opens and asks for your Mac password. Keep the iPod connected until it finishes. Your verified backup can be written back at any time from Restore.")
        }
    }

    private var recovery: some View {
        Card(title: "If something goes wrong", symbol: "lifepreserver") {
            VStack(alignment: .leading, spacing: 6) {
                Label("**Undo:** Restore ▸ Roll Back writes your original backup back.", systemImage: "arrow.uturn.backward")
                Label("**Doesn't boot:** hold Menu + Select to reset; when the Apple logo appears, hold Select + Play until “Do not disconnect” (disk mode). Then roll back.", systemImage: "power")
                Label("**Last resort:** restore in Finder. That reinstalls stock firmware and erases the music.", systemImage: "exclamationmark.triangle")
            }
            .font(.callout)
        }
    }
}

// MARK: - Restore

struct RestorePage: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        Page(step: .restore, subtitle: "Put your original firmware back.") {
            if let b = state.backup, b.verified, let model = state.model, let d = state.device {
                Card(title: "Roll back", symbol: "arrow.uturn.backward.circle") {
                    SpecRow(key: "backup", value: "firmware/" + b.url.lastPathComponent)
                    SpecRow(key: "sha256", value: b.sha256)
                    if model != .g4 {
                        SpecRow(key: "currently on iPod", value: state.lastFlashed.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?")
                        Text("Only the sectors that differ between those two images are written; the script refuses if the iPod holds anything else.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(role: .destructive) { confirm = true } label: {
                            Label("Roll Back to Original…", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.busy != nil || state.backupMatchesDevice == false)
                    }
                }
                .confirmationDialog("Write the original firmware back to \(d.partition)?", isPresented: $confirm) {
                    Button("Roll Back", role: .destructive) { Task { await state.runRollback() } }
                }
            } else {
                Callout(kind: .info, text: "Rolling back needs a connected, supported iPod and its verified backup in `firmware/`.")
            }
            Callout(kind: .info, text: "A firmware update or restore in Finder also removes the patches (and a restore erases the music).")
        }
    }
}

// MARK: - Console

struct ConsolePage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CONSOLE").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    let text = state.log.map { "[\($0.time.formatted(date: .omitted, time: .standard))] \($0.kind == .cmd ? "$ " : "")\($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear", systemImage: "trash") { state.log.removeAll() }
            }
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
