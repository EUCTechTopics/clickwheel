import Foundation
import CryptoKit
import Observation
import AppKit
import SwiftUI

enum Step: String, CaseIterable, Identifiable {
    case device, backup, patches, flash, restore, console
    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: return "Device"
        case .backup: return "Backup"
        case .patches: return "Patches"
        case .flash: return "Flash"
        case .restore: return "Restore"
        case .console: return "Console"
        }
    }
    var symbol: String {
        switch self {
        case .device: return "ipod"
        case .backup: return "externaldrive.badge.checkmark"
        case .patches: return "hammer"
        case .flash: return "bolt.horizontal"
        case .restore: return "arrow.uturn.backward.circle"
        case .console: return "terminal"
        }
    }
    var number: String {
        switch self {
        case .device: return "01"
        case .backup: return "02"
        case .patches: return "03"
        case .flash: return "04"
        case .restore: return "↺"
        case .console: return ">_"
        }
    }
}

enum StepStatus { case todo, ready, done, warn, blocked }

struct LogLine: Identifiable {
    enum Kind { case cmd, out, ok, err, info }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

struct BackupInfo: Equatable {
    var url: URL
    var sha256: String
    var verified: Bool
    var modified: Date
    var originSerial: String?
}

@MainActor
@Observable
final class AppState {
    var repo: URL?
    var device: Device?
    var cachedSysInfo: [String: [String: String]] = [:]   // per session, survives the unmount done by the scripts
    var step: Step = .device
    var log: [LogLine] = []
    var busy: String?
    var backup: BackupInfo?
    var backupConfirmed = false
    var check: PatchReport?
    var selected: Set<PatchID> = [.labels, .composers]
    var plan: PatchReport?
    var built: PatchReport?
    var flashed: URL?
    var flashFailed = false
    var alert: AlertInfo?

    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var critical = false
        /// Offer a button to System Settings ▸ Privacy & Security ▸ Full Disk Access.
        var fullDiskAccess = false
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private var timer: Timer?

    init() {
        repo = Self.locateRepo()
        if let repo { info("repository: \(repo.path)") } else { err("repository not found; choose it via Clickwheel ▸ Choose Repository…") }
        if let demo = ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO"] {
            // Developer aid for UI review: a simulated iPod photo, no device access at all.
            info("demo mode: simulated iPod, firmware folder \(demo)")
            demoFirmwareDir = URL(fileURLWithPath: demo)
            device = Device(disk: "disk4", partition: "disk4s2", partitionSize: 33_554_432, volumeName: "iPod", mountPoint: "/Volumes/iPod",
                            sysInfo: ["BoardHwName": "iPod P98", "ModelNumStr": "MA079", "pszSerialNumber": "DEMO0000",
                                      "buildID": "0x04218000 (4.2.1)", "visibleBuildID": "0x01218000 (1.2.1)"])
            Task { await refreshFiles() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan(quiet: true) }
        }
        Task { await scan(quiet: false) }
    }

    // MARK: repo

    static func locateRepo() -> URL? {
        let fm = FileManager.default
        func isRepo(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("scripts/patch.py").path) }
        if let saved = UserDefaults.standard.string(forKey: "repoPath"), isRepo(URL(fileURLWithPath: saved)) {
            return URL(fileURLWithPath: saved)
        }
        if let p = Bundle.main.object(forInfoDictionaryKey: "ClickwheelRepoPath") as? String, isRepo(URL(fileURLWithPath: p)) {
            return URL(fileURLWithPath: p)
        }
        var u = Bundle.main.bundleURL
        for _ in 0..<6 {
            u.deleteLastPathComponent()
            if isRepo(u) { return u }
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        for c in [cwd, cwd.deletingLastPathComponent()] where isRepo(c) { return c }
        return nil
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Clickwheel repository folder (the one containing scripts/patch.py)"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        guard FileManager.default.fileExists(atPath: u.appendingPathComponent("scripts/patch.py").path) else {
            alert = AlertInfo(title: "Not a Clickwheel repository", message: "\(u.path) has no scripts/patch.py.")
            return
        }
        UserDefaults.standard.set(u.path, forKey: "repoPath")
        repo = u
        info("repository: \(u.path)")
        Task { await refreshFiles() }
    }

    private var demoFirmwareDir: URL?
    var firmwareDir: URL? { demoFirmwareDir ?? repo?.appendingPathComponent("firmware") }
    var model: IPodModel? { device?.model }

    // MARK: log

    /// Everything in the console is also appended to ~/Library/Logs/Clickwheel.log.
    static let logFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clickwheel.log")

    private func append(_ l: LogLine) {
        log.append(l)
        let tag: String = switch l.kind { case .cmd: "$"; case .ok: "+"; case .err: "!"; case .info: "."; case .out: " " }
        let line = "\(ISO8601DateFormatter().string(from: l.time)) \(tag) \(l.text)\n"
        if let h = try? FileHandle(forWritingTo: Self.logFile) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: Self.logFile, atomically: true, encoding: .utf8)
        }
    }

    func info(_ s: String) { append(LogLine(kind: .info, text: s)) }
    func err(_ s: String) { append(LogLine(kind: .err, text: s)) }
    func ok(_ s: String) { append(LogLine(kind: .ok, text: s)) }
    func cmd(_ s: String) { append(LogLine(kind: .cmd, text: s)) }
    func out(_ s: String) {
        for l in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = String(l)
            let kind: LogLine.Kind = t.hasPrefix("OK") ? .ok
                : (t.hasPrefix("ABORT") || t.hasPrefix("ERROR") || t.contains("MISMATCH") || t.contains("execution error")) ? .err : .out
            append(LogLine(kind: kind, text: t))
        }
    }

    // MARK: device detection (read-only: diskutil and SysInfo)

    private var scanning = false
    /// False until the first diskutil scan has finished (so the UI doesn't flash "no iPod").
    var scannedOnce = false
    private var lastSerial: String?
    private var lastModel: IPodModel?

    /// Reads SysInfo off the main thread: the first read of a removable volume can wait on a
    /// macOS privacy prompt, and the UI must not hang meanwhile.
    nonisolated static func readSysInfo(_ mount: String) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            var sys: [String: String] = [:]
            guard let text = try? String(contentsOfFile: mount + "/iPod_Control/Device/SysInfo", encoding: .utf8) else { return sys }
            for line in text.split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2 { sys[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
            }
            return sys
        }.value
    }

    func scan(quiet: Bool) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let r = await Runner.run("/usr/sbin/diskutil", ["list", "-plist", "external"])
        guard r.ok, let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            if !quiet { err("diskutil list failed: \(r.stderr)") }
            return
        }
        defer { scannedOnce = true }
        var found: [Device] = []
        for d in disks {
            guard let disk = d["DeviceIdentifier"] as? String, let parts = d["Partitions"] as? [[String: Any]] else { continue }
            guard let fw = parts.first(where: { ($0["Content"] as? String) == "Apple_MDFW" }),
                  let fwID = fw["DeviceIdentifier"] as? String else { continue }
            let size = (fw["Size"] as? Int) ?? 0
            let data = parts.first(where: { ($0["Content"] as? String) == "Apple_HFS" })
            let mount = data?["MountPoint"] as? String
            var sys: [String: String] = [:]
            if let mount { sys = await Self.readSysInfo(mount) }
            if sys.isEmpty, let c = cachedSysInfo[fwID] { sys = c }  // unmounted by a script: reuse what we read before
            found.append(Device(disk: disk, partition: fwID, partitionSize: size, volumeName: data?["VolumeName"] as? String,
                                mountPoint: mount, sysInfo: sys))
        }
        let dev = found.first
        if let dev, !dev.sysInfo.isEmpty { cachedSysInfo[dev.partition] = dev.sysInfo }
        if dev != device {
            if let dev {
                info("found iPod on /dev/\(dev.disk): firmware partition \(dev.partition), \(dev.partitionSize) bytes"
                     + (dev.board.map { ", \($0)" } ?? "") + (dev.visibleBuildID.map { ", fw \($0)" } ?? ""))
                if found.count > 1 { err("several iPods connected; using \(dev.partition). Disconnect the others.") }
            } else if device != nil {
                info("iPod disconnected")
            }
            // Keep the session across the disconnect/reconnect of a reboot; reset for a different iPod.
            let otherIPod = dev != nil && (dev?.serial != lastSerial || dev?.model != lastModel)
            device = dev
            if let dev {
                if otherIPod && lastSerial != nil { check = nil; plan = nil; built = nil; flashed = nil; flashFailed = false; backupConfirmed = false }
                lastSerial = dev.serial; lastModel = dev.model
            }
            await refreshFiles()
        }
    }

    func eject() async {
        guard let d = device else { return }
        cmd("diskutil eject \(d.disk)")
        let r = await Runner.run("/usr/sbin/diskutil", ["eject", d.disk])
        out(r.combined)
        await scan(quiet: true)
    }

    // MARK: files

    func refreshFiles() async {
        guard let model, let dir = firmwareDir else { backup = nil; return }
        let url = dir.appendingPathComponent(model.backupFile)
        guard FileManager.default.fileExists(atPath: url.path) else { backup = nil; return }
        let shaFile = url.appendingPathExtension("sha256")
        let expected = (try? String(contentsOf: shaFile, encoding: .utf8))?.split(separator: " ").first.map(String.init)
        let actual = await Task.detached { () -> String? in
            guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }.value
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let origin = (try? String(contentsOf: url.appendingPathExtension("device"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        backup = BackupInfo(url: url, sha256: actual ?? "?", verified: actual != nil && actual == expected,
                            modified: attrs?[.modificationDate] as? Date ?? .distantPast, originSerial: origin)
        if let s = device?.serial, origin == s { backupConfirmed = true }
        if backup?.verified == true, check == nil { await runCheck() }
    }

    var backupMatchesDevice: Bool? {
        guard let b = backup, let s = device?.serial, let o = b.originSerial else { return nil }
        return o == s
    }
    var backupUsable: Bool { backup?.verified == true && (backupMatchesDevice ?? backupConfirmed) && backupMatchesDevice != false }

    // MARK: patch.py (never touches the device)

    private func patchPy(_ args: [String]) async -> PatchReport? {
        guard let repo else { return nil }
        let full = ["scripts/patch.py"] + args + ["--json"]
        cmd("python3 " + full.joined(separator: " "))
        let r = await Runner.run("/usr/bin/env", ["python3", "-I"] + full, cwd: repo)
        guard let rep = try? JSONDecoder().decode(PatchReport.self, from: Data(r.stdout.utf8)) else {
            err("patch.py produced no report: \(r.combined)")
            return nil
        }
        if let e = rep.error { err(e) }
        return rep
    }

    func runCheck() async {
        guard let model, backup != nil else { return }
        busy = "Checking firmware"
        defer { busy = nil }
        check = await patchPy(["--model", model.rawValue, "-i", backup!.url.path, "--check"])
        if let c = check, c.ok {
            for (n, p) in (c.patches ?? [:]).sorted(by: { $0.key < $1.key }) { out("patch \(n): \(p.state)") }
            if c.patchable == true { ok("OK: patchable (osos checksum \(hex32(c.osos!.checksum)) valid)") }
            else { err("Not patchable: this firmware is not the supported build. Nothing will be built.") }
        }
        if !seededSelection, let ds = deviceState, !ds.applied.isEmpty {
            selected = Set(ds.applied.compactMap(PatchID.init(rawValue:)))
            seededSelection = true
        }
        await updatePlan()
    }

    private var planTask: Task<Void, Never>?

    /// Recalculate the plan shortly after the last toggle, instead of once per click.
    func schedulePlan() {
        built = nil
        planTask?.cancel()
        planTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await updatePlan()
        }
    }

    func updatePlan() async {
        guard let model, let b = backup, check?.patchable == true, !selected.isEmpty else { plan = nil; return }
        let flags = PatchID.allCases.filter { selected.contains($0) }.map(\.flag)
        plan = await patchPy(["--model", model.rawValue, "-i", b.url.path, "--plan"] + flags)
    }

    func build() async {
        guard let model, let dir = firmwareDir, let b = backup, check?.patchable == true, !selected.isEmpty else { return }
        busy = "Building patched copy"
        defer { busy = nil }
        var out = dir.appendingPathComponent(model.patchedFile)
        if FileManager.default.fileExists(atPath: out.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            out = dir.appendingPathComponent(model.patchedFile.replacingOccurrences(of: ".bin", with: "-\(f.string(from: Date())).bin"))
            info("\(model.patchedFile) already exists; keeping it and writing \(out.lastPathComponent)")
        }
        let flags = PatchID.allCases.filter { selected.contains($0) }.map(\.flag)
        guard let rep = await patchPy(["--model", model.rawValue, "-i", b.url.path] + flags + ["-o", out.path]), rep.ok else { return }
        built = rep
        ok("OK: built \(out.lastPathComponent) (\(rep.changes?.count ?? 0) bytes in \(rep.sectors?.count ?? 0) sectors, checksum \(hex32(rep.new_checksum ?? 0)))")
        ok("sha256 \(rep.output_sha256 ?? "")")
        advance(to: .flash)
    }

    func advance(to s: Step) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.snappy) { step = s }
        }
    }

    // MARK: privileged steps (macOS asks the user for their password)

    var terminalTask: Task<RunResult?, Never>?

    /// The Terminal step in progress, shown as a live panel while the user types their password.
    struct TerminalSession: Identifiable {
        let id = UUID()
        let title: String
        let command: String
        let started = Date()
        var output = ""
    }
    var terminal: TerminalSession?

    /// Stop waiting for the Terminal window (the command there is not interrupted).
    func stopWaiting() { terminalTask?.cancel() }

    private func privileged(_ title: String, _ command: [String]) async -> RunResult? {
        guard let repo else { return nil }
        busy = "\(title): continue in Terminal"
        let line = "sudo " + command.joined(separator: " ")
        terminal = TerminalSession(title: title, command: line)
        defer { busy = nil; terminalTask = nil; terminal = nil }
        cmd(line)
        info("opened Terminal: type your Mac password there")
        let task = Task { await Runner.runInTerminal(command, cwd: repo, title: title) { [weak self] s in self?.terminal?.output = s } }
        terminalTask = task
        guard let r = await task.value else {
            info("stopped waiting for Terminal")
            return nil
        }
        out(r.combined)
        if r.combined.contains("Operation not permitted") {
            err("macOS blocked access to the iPod (Operation not permitted). Nothing was written.")
            alert = AlertInfo(title: "macOS blocked access to the iPod",
                              message: "The script couldn't open the firmware partition (“Operation not permitted”). Nothing was read or written.\n\nGive Terminal access in System Settings ▸ Privacy & Security (Full Disk Access, or Files & Folders ▸ Removable Volumes), then try again.",
                              fullDiskAccess: true)
        }
        if !r.combined.contains("OK: ") { await remount() }
        return r
    }

    /// The scripts unmount the iPod; after a failed step, mount it again so Finder and SysInfo come back.
    private func remount() async {
        guard let d = device else { return }
        cmd("diskutil mountDisk \(d.disk)")
        out(await Runner.run("/usr/sbin/diskutil", ["mountDisk", d.disk]).combined)
    }

    func runBackup() async {
        guard let model, let d = device else { return }
        guard let r = await privileged("Backing up firmware", model.backupCommand(part: d.partition)) else { return }
        if r.stdout.contains("OK: backup verified") {
            if let s = d.serial, let dir = firmwareDir {
                try? (s + "\n").write(to: dir.appendingPathComponent(model.backupFile + ".device"), atomically: true, encoding: .utf8)
            }
            ok("backup verified; this is your way back")
            await refreshFiles()
            backupConfirmed = true
            if let b = backup, check != nil {
                setDeviceState(DeviceState(patches: backupStates, image: b.url.path, source: .backup, date: Date()))
            }
            if check?.patchable == true { advance(to: .patches) }
        } else {
            alert = AlertInfo(title: "Backup did not complete", message: "The backup script did not report “OK: backup verified”. Nothing was written to the iPod.\n\nLast output:\n" + r.combined.split(separator: "\n").suffix(3).joined(separator: "\n"))
        }
    }

    func runFlash() async {
        guard let model, let d = device, let img = built?.output else { return }
        let from = await currentImage()
        if let from { info("on the iPod now: \(URL(fileURLWithPath: from).lastPathComponent)") }
        guard let r = await privileged("Writing firmware", model.writeCommand(part: d.partition, image: img, from: from)) else { return }
        if r.stdout.contains("OK: firmware partition now matches") {
            flashed = URL(fileURLWithPath: img)
            flashFailed = false
            var states = backupStates
            for p in built?.applied ?? [] { states[p] = "applied" }
            setDeviceState(DeviceState(patches: states, image: img, source: .write, date: Date()))
            ok("firmware written and verified")
        } else {
            flashFailed = true
            let mismatch = r.combined.contains("MISMATCH") || r.combined.contains("WRITE FAILED")
            let unknown = r.combined.contains("matches neither image") || r.combined.contains("device differs from")
            alert = AlertInfo(title: mismatch ? "Do not unplug the iPod" : "Write did not complete",
                              message: mismatch
                                ? "The read-back did not match. Leave the iPod connected and use Restore ▸ Roll back to write your backup back."
                                : unknown
                                ? "The iPod holds different firmware than Clickwheel expected, so the script stopped before writing. Use Device ▸ Read from iPod to see what's on it, then try again."
                                : "The write script stopped before writing (see the console). The iPod was not changed.",
                              critical: mismatch)
        }
    }

    func runRollback() async {
        guard let model, let d = device, let b = backup, b.verified else { return }
        let from = await currentImage()
        if from == b.url.path {
            alert = AlertInfo(title: "Already original", message: "As far as Clickwheel knows, this iPod already runs the firmware from your backup. Use Read from iPod to double-check.")
            return
        }
        guard let r = await privileged("Rolling back", model.rollbackCommand(part: d.partition, image: from ?? "")) else { return }
        if r.stdout.contains("OK: firmware partition now matches") {
            flashed = nil
            setDeviceState(DeviceState(patches: backupStates, image: b.url.path, source: .rollback, date: Date()))
            ok("original firmware restored")
        } else {
            alert = AlertInfo(title: "Rollback did not complete", message: "See the console. If the iPod holds firmware Clickwheel doesn't know, use Read from iPod first. If it doesn't boot, put it in disk mode and try again, or restore it in Finder.", critical: true)
        }
    }

    /// Read-only: ask the iPod what's on it (sudo in Terminal: dd + patch.py --check).
    func readDeviceState() async {
        guard let model, let d = device else { return }
        guard let r = await privileged("Reading patches from the iPod", model.stateCommand(part: d.partition)) else { return }
        guard let line = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let rep = try? JSONDecoder().decode(PatchReport.self, from: Data(line.utf8)), rep.ok, let p = rep.patches else {
            alert = AlertInfo(title: "Couldn't read the iPod", message: "The read-only check didn't produce a report. See the console. Nothing was written.")
            return
        }
        let states = p.mapValues(\.state)
        let img = await imageMatching(states)
        setDeviceState(DeviceState(patches: states, image: img, source: .read, date: Date()))
        let applied = PatchID.allCases.filter { states[$0.rawValue] == "applied" }.map(\.rawValue)
        ok("on the iPod: " + (applied.isEmpty ? "stock firmware (no patches)" : applied.joined(separator: " + ")))
        if states.values.contains("mismatch") { err("some patch locations hold unexpected bytes: not the supported firmware build") }
        if let img { info("matches \(URL(fileURLWithPath: img).lastPathComponent)") }
    }

    // MARK: what's on the iPod (remembered per iPod; exact after a backup, write, rollback or read)

    struct DeviceState: Codable, Equatable {
        enum Source: String, Codable { case backup, write, rollback, read, remembered }
        var patches: [String: String]     // patch -> original | applied | mismatch
        var image: String?                // a local image identical to the iPod's firmware, if known
        var source: Source
        var date: Date

        var applied: [String] { PatchID.allCases.map(\.rawValue).filter { patches[$0] == "applied" } }
        var isStock: Bool { PatchID.allCases.allSatisfy { patches[$0.rawValue] == "original" } }
        var sourceText: String {
            switch source {
            case .backup: return "from the backup"
            case .write: return "verified by read-back after writing"
            case .rollback: return "verified by read-back after the rollback"
            case .read: return "read from the iPod"
            case .remembered: return "remembered, not verified"
            }
        }
    }

    private var stateKey: String? {
        guard let d = device, let m = d.model else { return nil }
        return "deviceState.\(d.serial ?? "model-" + m.rawValue)"
    }
    private var stateVersion = 0
    private var seededSelection = false

    var deviceState: DeviceState? {
        _ = stateVersion
        guard let k = stateKey else { return nil }
        if let data = UserDefaults.standard.data(forKey: k), let s = try? JSONDecoder().decode(DeviceState.self, from: data) { return s }
        // Older Clickwheel versions only remembered the last image written for this model.
        if let m = model, let p = UserDefaults.standard.string(forKey: "flashed.\(m.rawValue)"), FileManager.default.fileExists(atPath: p) {
            return DeviceState(patches: [:], image: p, source: .remembered,
                               date: (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast)
        }
        return nil
    }

    func setDeviceState(_ s: DeviceState) {
        guard let k = stateKey, let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: k)
        stateVersion += 1
        // The toggles start from what's on the iPod.
        if !s.applied.isEmpty { selected = Set(s.applied.compactMap(PatchID.init(rawValue:))) }
        schedulePlan()
    }

    var backupStates: [String: String] { (check?.patches ?? [:]).mapValues(\.state) }

    /// Patch states of the selection, as they would be on the iPod after writing it.
    var selectionStates: [String: String] {
        var st = backupStates
        for p in selected { st[p.rawValue] = "applied" }
        return st
    }
    var selectionIsInstalled: Bool {
        guard let d = deviceState, !d.patches.isEmpty else { return false }
        return PatchID.allCases.allSatisfy { d.patches[$0.rawValue] == selectionStates[$0.rawValue] }
    }

    /// The local image that equals the firmware on the iPod, if Clickwheel can tell.
    func currentImage() async -> String? {
        if let s = deviceState {
            if let i = s.image, FileManager.default.fileExists(atPath: i) { return i }
            if !s.patches.isEmpty { return await imageMatching(s.patches) }
        }
        return backup?.url.path
    }

    /// Find an image in firmware/ (the backup or a patched copy built from it) with these patch states.
    func imageMatching(_ states: [String: String]) async -> String? {
        guard let model, let dir = firmwareDir, let b = backup else { return nil }
        if PatchID.allCases.allSatisfy({ states[$0.rawValue] == backupStates[$0.rawValue] }) { return b.url.path }
        let stem = model.patchedFile.replacingOccurrences(of: ".bin", with: "")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(stem) && $0.hasSuffix(".bin") }.sorted().reversed()
        for f in files {
            let path = dir.appendingPathComponent(f).path
            let r = await Runner.run("/usr/bin/env", ["python3", "-I", "scripts/patch.py", "--model", model.rawValue, "-i", path, "--check", "--json"], cwd: repo)
            guard let rep = try? JSONDecoder().decode(PatchReport.self, from: Data(r.stdout.utf8)), let p = rep.patches else { continue }
            if PatchID.allCases.allSatisfy({ p[$0.rawValue]?.state == states[$0.rawValue] }) { return path }
        }
        return nil
    }

    // MARK: status

    func status(_ s: Step) -> StepStatus {
        switch s {
        case .device:
            guard let d = device else { return .todo }
            guard d.model != nil else { return .blocked }
            return d.firmwareMatches == false ? .blocked : .done
        case .backup:
            guard device?.model != nil else { return .todo }
            if let b = backup { return b.verified ? (backupUsable ? .done : .warn) : .blocked }
            return .ready
        case .patches:
            if check?.patchable == false { return .blocked }
            if built != nil { return .done }
            return backupUsable ? .ready : .todo
        case .flash:
            if flashFailed { return .blocked }
            if flashed != nil { return .done }
            return built != nil ? .ready : .todo
        case .restore:
            return backup?.verified == true ? .ready : .todo
        case .console:
            return log.contains { $0.kind == .err } ? .warn : .ready
        }
    }
}
