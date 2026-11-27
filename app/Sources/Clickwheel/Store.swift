import Foundation
import Observation
import AppKit
import SwiftUI

/// What the main window shows. Derived from the app state, never set directly.
enum Phase: Equatable {
    case searching, connect
    case unsupported(String)
    case ready
}

struct LogLine: Identifiable {
    enum Kind { case cmd, out, ok, err, info }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

@MainActor
@Observable
final class AppState {
    var repo: URL?
    var device: Device?
    var cachedSysInfo: [String: [String: String]] = [:]   // per session, survives the unmount done by the scripts
    var log: [LogLine] = []
    var busy: String?
    /// patch.py --check of the iPod's firmware as Clickwheel last read or wrote it (Library copy).
    var check: PatchReport?
    /// The switches. All off until Clickwheel knows what's on the iPod; then they follow the iPod.
    var selected: Set<PatchID> = []
    /// Picture files chosen for picture changes (e.g. the "Do not disconnect" picture), not yet on the iPod.
    var customPictures: [PatchID: URL] = [:]
    /// Changes switched on with your own picture (Option-click), as opposed to their normal effect.
    var ownPicture: Set<PatchID> = []
    /// Easter egg (Command-click on the boot logo switch): Apple's logo mirrored left-right, not yet on the iPod.
    var mirrored: Set<PatchID> = []
    /// A new picture (a chosen file or the mirror) waits to be written.
    func newPicture(_ p: PatchID) -> Bool { customPictures[p] != nil || mirrored.contains(p) }
    var plan: PatchReport?
    /// The boot logo and DnD picture as they will be after Apply (from the plan), for the preview.
    var previewPictures: [PatchID: NSImage] = [:]
    var previewMode: PreviewMode = .menus
    /// The iPod's own music (read-only from its iTunesDB), so the preview shows the user's labels.
    var music: [LibraryReport.Genre]?
    var songs: [LibraryReport.Song]?
    private var musicFrom: String?
    var built: PatchReport?
    /// The image just written and verified; nil again once the user changes a switch.
    var flashed: URL?
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
            // Developer aid for UI review: a simulated iPod photo, no device access at all. The folder
            // stands in for the Library folder and holds ipod.bin.
            info("demo mode: simulated iPod, firmware folder \(demo)")
            demoLibrary = URL(fileURLWithPath: demo)
            // CLICKWHEEL_DEMO_SCREEN=Startup|Connected opens that preview screen (for screenshots)
            if let m = ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO_SCREEN"].flatMap(PreviewMode.init(rawValue:)) { previewMode = m }
            device = Device(disk: "disk4", partition: "disk4s2", partitionSize: 33_554_432, volumeName: "Demo's iPod", mountPoint: "/Volumes/iPod",
                            sysInfo: ["BoardHwName": "iPod P98", "ModelNumStr": "MA079", "pszSerialNumber": "DEMO0000",
                                      "buildID": "0x04218000 (4.2.1)", "visibleBuildID": "0x01218000 (1.2.1)"],
                            capacity: 60_011_642_880)
            scannedOnce = true
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

    var model: IPodModel? { device?.model }
    /// The changes offered for the connected iPod.
    var patchIDs: [PatchID] { PatchID.allCases.filter { $0.available(on: model) } }

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

    /// USB product ID of the iPod behind a disk (same lookup as scripts/usb_product.py), off the main thread.
    nonisolated static func usbProduct(disk: String) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            let r = await Runner.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOUSBHostDevice", "-l"])
            guard r.ok, let roots = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [[String: Any]]
            else { return nil }
            func holds(_ n: [String: Any]) -> Bool {
                if n["BSD Name"] as? String == disk { return true }
                return ((n["IORegistryEntryChildren"] as? [[String: Any]]) ?? []).contains(where: holds)
            }
            return roots.first { ($0["idVendor"] as? Int) == 1452 && holds($0) }?["idProduct"] as? Int
        }.value
    }
    private var usbProducts: [String: Int] = [:]

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
            // cached per disk and size (macOS reuses disk names when iPods are swapped)
            let usbKey = "\(disk)|\((d["Size"] as? Int) ?? 0)"
            if usbProducts[usbKey] == nil, let p = await Self.usbProduct(disk: disk) { usbProducts[usbKey] = p }
            found.append(Device(disk: disk, partition: fwID, partitionSize: size, volumeName: data?["VolumeName"] as? String,
                                mountPoint: mount, sysInfo: sys, capacity: d["Size"] as? Int, usbProduct: usbProducts[usbKey]))
        }
        let present = Set(disks.map { "\(($0["DeviceIdentifier"] as? String) ?? "")|\(($0["Size"] as? Int) ?? 0)" })
        usbProducts = usbProducts.filter { present.contains($0.key) }
        let dev = found.first
        if let dev, !dev.sysInfo.isEmpty { cachedSysInfo[dev.partition] = dev.sysInfo }
        if dev != device {
            if let dev {
                info("found iPod on /dev/\(dev.disk): firmware partition \(dev.partition), \(dev.partitionSize) bytes"
                     + (dev.board.map { ", \($0)" } ?? "") + (dev.visibleBuildID.map { ", fw \($0)" } ?? ""))
                if found.count > 1 { err("several iPods connected; using \(dev.partition). Disconnect the others.") }
            } else if device != nil {
                info("iPod disconnected")
                flashed = nil
            }
            // Keep the session across the disconnect/reconnect of a reboot; reset for a different iPod.
            let otherIPod = dev != nil && (dev?.serial != lastSerial || dev?.model != lastModel)
            device = dev
            if let dev {
                // (lastModel: iPod Videos often have no serial in SysInfo; a model change is another iPod too)
                if otherIPod && (lastSerial != nil || lastModel != nil) { check = nil; plan = nil; built = nil; flashed = nil; customPictures = [:]; ownPicture = []; mirrored = []
                    music = nil; songs = nil; musicFrom = nil }
                lastSerial = dev.serial; lastModel = dev.model
                await loadMusic()
            }
            await refreshFiles()
            if deviceState == nil && !working { selected = [] }
        }
        if device == nil { readOnConnect = false }
        readIfNewlyConnected()
    }

    // MARK: read on connect

    /// Set once this connection's automatic read has been started (or skipped); reset on disconnect.
    private var readOnConnect = false
    /// iPods (by Library folder) whose firmware Clickwheel read or wrote and verified since it opened.
    private var knownThisSession: Set<String> = []

    /// Read a newly connected iPod once it's recognised, so the switches show what's really on it.
    /// Skipped when Clickwheel already read or wrote this iPod in this session (e.g. it's back after
    /// being ejected to restart), and not repeated if the user cancels the password dialog.
    private func readIfNewlyConnected() {
        guard !readOnConnect, demoLibrary == nil, device != nil, phase == .ready, !working, let lib = library else { return }
        readOnConnect = true
        if knownThisSession.contains(lib.path) { return }
        info("new iPod connected: reading its firmware to see what's on it")
        Task { await self.readDeviceState() }   // own task: device detection keeps running meanwhile
    }

    func eject() async {
        guard let d = device else { return }
        cmd("diskutil eject \(d.disk)")
        let r = await Runner.run("/usr/sbin/diskutil", ["eject", d.disk])
        out(r.combined)
        await scan(quiet: true)
    }

    // MARK: files (~/Library/Application Support/Clickwheel/<iPod>/)
    //
    // ipod.bin      the iPod's firmware as Clickwheel last read it or wrote and verified it
    // pending.bin   an image whose write didn't complete; the next Apply finishes it first
    // build-*.bin   the image being installed (becomes ipod.bin once it's verified on the iPod)

    private var demoLibrary: URL?

    /// This iPod's folder in ~/Library/Application Support/Clickwheel (never the repository).
    var library: URL? {
        if let demoLibrary { return demoLibrary }
        guard let d = device, let m = d.model else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clickwheel").appendingPathComponent(d.serial ?? "iPod-\(m.rawValue)")
    }
    var current: URL? { library?.appendingPathComponent("ipod.bin") }
    var pending: URL? { library?.appendingPathComponent("pending.bin") }
    var hasPending: Bool { pending.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    /// When and how ipod.bin was made ("read" or "write"), kept next to it.
    var currentInfo: (source: String, date: Date)? {
        guard let c = current, let attrs = try? FileManager.default.attributesOfItem(atPath: c.path) else { return nil }
        let how = (try? String(contentsOf: c.appendingPathExtension("how"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (how ?? "read", attrs[.modificationDate] as? Date ?? .distantPast)
    }

    func refreshFiles() async {
        guard let c = current, FileManager.default.fileExists(atPath: c.path) else { check = nil; plan = nil; return }
        if check == nil || check?.input != c.path { await runCheck() }
    }

    private func remove(_ u: URL) {
        let fm = FileManager.default
        for p in [u, u.appendingPathExtension("sha256"), u.appendingPathExtension("how")] where fm.fileExists(atPath: p.path) {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p.path)
            try? fm.removeItem(at: p)
        }
    }

    /// Make `u` the new ipod.bin (after it was verified on the iPod).
    private func adopt(_ u: URL, how: String) {
        guard let c = current, u != c else { return }
        remove(c)
        let fm = FileManager.default
        try? fm.moveItem(at: u, to: c)
        if let sha = try? String(contentsOf: u.appendingPathExtension("sha256"), encoding: .utf8) {
            try? sha.replacingOccurrences(of: u.lastPathComponent, with: c.lastPathComponent)
                .write(to: c.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: u.appendingPathExtension("sha256"))
        }
        try? (how + "\n").write(to: c.appendingPathExtension("how"), atomically: true, encoding: .utf8)
    }

    // MARK: the iPod's music (read-only, for the preview)

    /// Read the library on the iPod's data volume once per iPod and database version; kept while it's
    /// unmounted for Apply. Keyed by disk, mount point and the iTunesDB's date and size, since two iPods
    /// without a serial both mount as /Volumes/iPod.
    private func loadMusic() async {
        guard let repo, let d = device, let mp = d.mountPoint else { return }
        let db = (try? FileManager.default.attributesOfItem(atPath: mp + "/iPod_Control/iTunes/iTunesDB")) ?? [:]
        let key = [d.disk, d.partition, mp, d.model?.rawValue ?? "",
                   "\((db[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)", "\((db[.size] as? Int) ?? 0)"]
            .joined(separator: "|")
        guard key != musicFrom else { return }
        let r = await Runner.run("/usr/bin/env", ["python3", "-I", "scripts/library.py", mp, "--json"], cwd: repo)
        guard let rep = try? JSONDecoder().decode(LibraryReport.self, from: Data(r.stdout.utf8)), rep.ok else { return }
        musicFrom = key
        let g = rep.genres ?? []
        music = g.isEmpty ? nil : g          // no songs with a genre: the preview shows its examples
        songs = g.isEmpty ? nil : rep.songs
        info("read the iPod's music library for the preview: \(g.count) genres/labels")
    }

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

    /// Check ipod.bin; the switches then show what's on the iPod.
    func runCheck() async {
        guard let model, let c = current, FileManager.default.fileExists(atPath: c.path) else { return }
        check = await patchPy(["--model", model.rawValue, "-i", c.path, "--check"])
        if let c = check, c.ok {
            for (n, p) in (c.patches ?? [:]).sorted(by: { $0.key < $1.key }) { out("patch \(n): \(p.state)") }
            if c.patchable == true { ok("OK: patchable (osos checksum \(hex32(c.osos!.checksum)) valid)") }
            else { err("Not patchable: this firmware is not the supported build. Nothing will be built.") }
        }
        if let ds = deviceState {
            selected = Set(ds.applied.compactMap(PatchID.init(rawValue:)))
            // your own picture (e.g. a boot logo) is on: the switch shows on, with that picture kept; a
            // picture chosen but not yet written stays chosen (Apply re-reads the iPod before building)
            ownPicture = Set(patchIDs.filter { $0.ownPictureOptional(on: model)
                && (ds.patches[$0.rawValue] == "custom" || newPicture($0)) })
            selected.formUnion(ownPicture)
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
        guard let model, let c = current, let lib = library, check?.patchable == true else {
            plan = nil; previewPictures = [:]; return
        }
        let dir = lib.appendingPathComponent("preview")
        plan = await patchPy(["--model", model.rawValue, "-i", c.path, "--plan", "--preview", dir.path] + selectionFlags)
        var pics: [PatchID: NSImage] = [:]
        for (n, path) in plan?.previews ?? [:] {
            if let p = PatchID(rawValue: n), let img = NSImage(contentsOfFile: path) { pics[p] = img }
        }
        previewPictures = pics
    }

    /// Build the selection from ipod.bin into a new file next to it.
    private func build() async -> URL? {
        guard let model, let c = current, let lib = library, check?.patchable == true else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = lib.appendingPathComponent("build-\(f.string(from: Date())).bin")
        guard let rep = await patchPy(["--model", model.rawValue, "-i", c.path] + selectionFlags + ["-o", out.path]), rep.ok else {
            alert = AlertInfo(title: "Couldn't prepare the new software", message: "Nothing was changed on your iPod. Details ▸ Log shows what went wrong.")
            return nil
        }
        built = rep
        if let r = rep.removed, !r.isEmpty { info("removed: " + r.joined(separator: ", ")) }
        if rep.result_stock == true { ok("OK: the result is identical to Apple's original software") }
        ok("OK: built \(out.lastPathComponent) (\(rep.changes?.count ?? 0) bytes in \(rep.sectors?.count ?? 0) sectors, checksum \(hex32(rep.new_checksum ?? 0)))")
        return out
    }

    /// patch.py flags for the selection. `--exact`: switches that are off put Apple's original bytes back.
    var selectionFlags: [String] {
        ["--exact"] + patchIDs.filter { selected.contains($0) }.flatMap { p -> [String] in
            guard p.takesPicture || ownPicture.contains(p) else { return [p.flag] }
            // a newly chosen file, or keep the custom picture that's already on the iPod
            return [p.pictureFlag, customPictures[p]?.path ?? (mirrored.contains(p) ? "mirror" : "keep")]
        }
    }

    // MARK: device steps (macOS's own password dialog; no Terminal, nothing runs as root)

    /// The stages of an operation, shown as a row of steps while it runs.
    enum Stage: String, CaseIterable {
        case prepare = "Preparing"
        case install = "Installing"
        case verify = "Checking"
        case read = "Reading"
    }
    /// The running operation's stages (empty when idle), the current one and its progress.
    var stages: [Stage] = []
    var stage: Stage?
    var progress: Double?
    var working: Bool { !stages.isEmpty }
    /// While a write is paced (see `paced`), the script's own progress only sets these flags.
    private var pacing = false
    private var paceVerify = false
    private var paceDone = false

    private func begin(_ s: [Stage]) { stages = s; stage = s.first; progress = s.first == .prepare ? 0 : nil }
    private func end() { stages = []; stage = nil; progress = nil; busy = nil }

    /// One password dialog for everything this operation needs on the firmware partition.
    private func authorize(read: Bool, write: Bool, prompt: String) async -> AuthSession? {
        guard let d = device else { return nil }
        busy = "Waiting for your Mac password"
        cmd("authopen: authorize \([read ? "read" : nil, write ? "write" : nil].compactMap { $0 }.joined(separator: " + ")) /dev/r\(d.partition)")
        do {
            return try await AuthSession.make(path: "/dev/r\(d.partition)", read: read, write: write, prompt: prompt)
        } catch AuthSession.Failure.cancelled {
            info("password dialog cancelled; nothing was read or written")
        } catch {
            err("\(error)")
            alert = AlertInfo(title: "macOS didn't give access to the iPod", message: "\(error)\n\nNothing was read or written.")
        }
        return nil
    }

    private func script(_ name: String, _ args: [String]) async -> RunResult {
        cmd("python3 scripts/\(name) " + args.joined(separator: " "))
        let r = await Runner.run("/usr/bin/python3", ["-I", "scripts/\(name)"] + args, cwd: repo)
        out(r.combined)
        return r
    }

    /// Checks the partition and the model, then unmounts the iPod (write_fd.py prepare).
    private func prepareDevice() async -> Bool {
        guard let model, let d = device else { return false }
        busy = "Checking your iPod"
        let r = await script("write_fd.py", ["prepare", model.rawValue, d.partition])
        guard r.ok, r.stdout.contains("OK: ready") else {
            await remount()
            alert = AlertInfo(title: "Stopped before touching the iPod", message: "Clickwheel's checks didn't pass. Nothing was read or written.\n\n" + r.combined.split(separator: "\n").suffix(2).joined(separator: "\n"))
            return false
        }
        return true
    }

    /// Runs a script with a handle to the firmware partition as stdin (from the session's
    /// authorization; read-only or read-write). The script checks it is exactly this partition.
    /// Returns nil when the handle couldn't be opened (an alert says why).
    private func withHandle(_ auth: AuthSession, writable: Bool, _ name: String, _ args: [String], working: String) async -> RunResult? {
        guard let model, let repo else { return nil }
        cmd("authopen (\(writable ? "read-write" : "read-only")) \(auth.path)")
        let fd: Int32
        do {
            fd = try await auth.open(writable: writable)
        } catch {
            err("\(error)")
            let blocked = "\(error)".contains("Operation not permitted")
            alert = AlertInfo(title: blocked ? "macOS blocked access to the iPod" : "Couldn't open the iPod",
                              message: blocked
                                ? "macOS didn't let Clickwheel open the firmware partition. Nothing was read or written.\n\nAllow Clickwheel in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again."
                                : "\(error)\n\nNothing was read or written.",
                              fullDiskAccess: blocked)
            return nil
        }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0 else {
            err("the handle from authopen is not open (fd \(fd)); nothing was read or written")
            alert = AlertInfo(title: "Couldn't open the iPod", message: "Clickwheel lost the handle to the iPod. Nothing was read or written. Please try again.")
            return nil
        }
        info("authopen handle: fd \(fd), mode \(String(fst.st_mode, radix: 8)), rdev \(String(UInt32(bitPattern: fst.st_rdev), radix: 16))")

        busy = working
        cmd("python3 scripts/\(name) " + args.joined(separator: " ") + " < \(auth.path)")
        let total = Double(model.partitionSize)
        let readsTwice = name == "backup_fd.py" && args.first == "dump"
        let r = await Runner.run("/usr/bin/python3", ["-I", "scripts/\(name)"] + args, cwd: repo, stdin: fd) { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                if line.hasPrefix("progress: "), !self.pacing, self.stage != .prepare,
                   let n = Double(line.dropFirst(10).split(separator: " ").first ?? "") {
                    // A read goes over the iPod twice: each pass is half of the bar.
                    let second = self.busy == "Comparing with a second read"
                    self.progress = readsTwice ? (second ? 0.5 : 0) + n / total / 2 : n / total
                } else if line.hasPrefix("Reading the iPod a second time") {
                    self.busy = "Comparing with a second read"
                } else if line.contains("to write:") {
                    self.busy = "Writing to your iPod"
                } else if line.hasPrefix("readback") {
                    if self.pacing { self.paceVerify = true }
                    self.busy = "Reading it back to check"
                }
            }
        }
        out(r.stdout.split(separator: "\n").filter { !$0.hasPrefix("progress: ") }.joined(separator: "\n"))
        return r
    }

    /// Mount the iPod again so Finder and SysInfo come back.
    private func remount() async {
        guard let d = device else { return }
        cmd("diskutil mountDisk \(d.disk)")
        out(await Runner.run("/usr/sbin/diskutil", ["mountDisk", d.disk]).combined)
    }

    /// Read the iPod's firmware into ipod.bin (read twice and compared), then check it.
    private func readIntoLibrary(_ auth: AuthSession) async -> Bool {
        guard let model, let d = device, let c = current else { return false }
        guard let r = await withHandle(auth, writable: false, "backup_fd.py", ["dump", model.rawValue, d.partition, c.path],
                                       working: "Reading your iPod") else { return false }
        guard r.stdout.contains("OK: read verified") else {
            alert = AlertInfo(title: "Couldn't read the iPod", message: "Nothing was changed on your iPod.\n\n" + r.combined.split(separator: "\n").suffix(2).joined(separator: "\n"))
            return false
        }
        try? "read\n".write(to: c.appendingPathExtension("how"), atomically: true, encoding: .utf8)
        if let lib = library { knownThisSession.insert(lib.path) }
        check = nil
        await runCheck()
        return check?.ok == true
    }

    /// Apply the selection: one password dialog, then read the iPod as it is now, build the
    /// selection from that, write only the sectors that differ and read them back. If an earlier
    /// write didn't complete (pending.bin), Apply finishes that one first.
    func apply() async {
        guard device != nil, current != nil, !working else { return }
        let wanted = selected
        // Re-reading the iPod resets the switches to what's on it; keep the user's choice, including
        // flip vs own picture (e.g. own picture/mirror on the iPod → flip selected must still write).
        let wantedOwn = ownPicture
        begin([.prepare, .install, .verify])
        defer { end() }
        guard let auth = await authorize(read: true, write: true,
                                          prompt: "Clickwheel wants to apply your tweaks to the iPod. Your music isn't touched.") else { return }
        guard await prepareDevice() else { return }

        if hasPending, let p = pending, let c = current {
            info("finishing an earlier install that didn't complete: \(p.lastPathComponent)")
            await paced(.install) { await self.write(auth, to: p, from: c) }
            if flashed == nil { await remount() }
            return
        }

        busy = "Reading your iPod"
        guard await readIntoLibrary(auth) else { await remount(); return }
        selected = wanted
        ownPicture = wantedOwn
        guard check?.patchable == true else {
            await remount()
            alert = AlertInfo(title: "Clickwheel can't change this iPod",
                              message: "This iPod's software isn't the exact version the changes were made for. Nothing was changed.")
            return
        }
        if selectionIsInstalled {
            ok("the iPod already has this selection; nothing to write")
            await remount()
            flashed = current
            return
        }
        busy = "Preparing the new software"
        guard let target = await build(), let c = current else { await remount(); return }
        await paced(.install) { await self.write(auth, to: target, from: c) }
        if flashed == nil { await remount() }
    }

    /// write_fd.py: change the iPod from `from` to `to` (only the differing sectors) and read back.
    private func write(_ auth: AuthSession, to: URL, from: URL) async {
        guard let model, let d = device, let p = pending else { return }
        guard let r = await withHandle(auth, writable: true, "write_fd.py", ["write", model.rawValue, d.partition, to.path, from.path],
                                       working: "Writing to your iPod") else { if to != p { remove(to) }; return }
        if r.stdout.contains("OK: firmware partition now matches") {
            adopt(to, how: "write")
            if let lib = library { knownThisSession.insert(lib.path) }
            if to != p { remove(p) }
            customPictures = [:]
            mirrored = []
            check = nil
            await runCheck()
            flashed = current
            ok("firmware written and verified")
            return
        }
        let mismatch = r.combined.contains("MISMATCH") || r.combined.contains("WRITE FAILED")
        if mismatch {
            // Part of it may be on the iPod: keep the target so the next Apply finishes it.
            if to != p { remove(p); try? FileManager.default.moveItem(at: to, to: p)
                try? FileManager.default.moveItem(at: to.appendingPathExtension("sha256"), to: p.appendingPathExtension("sha256")) }
            alert = AlertInfo(title: "Do not unplug the iPod",
                              message: "Checking the iPod after writing found a difference. Leave it connected and press Apply again: Clickwheel then finishes the install.",
                              critical: true)
        } else {
            if to != p { remove(to) }
            let unknown = r.combined.contains("matches neither image") || r.combined.contains("device differs from")
            alert = AlertInfo(title: "Nothing was changed",
                              message: unknown
                                ? "The iPod changed since Clickwheel read it, so nothing was written. Please try again."
                                : "Your iPod was not changed. Details ▸ Log shows what happened.")
        }
    }

    /// Runs a write while showing it on one progress bar: `first` fills the bar from 0 to 100% over
    /// at least 3 seconds, then Checking shows a full bar for at least 2 seconds, so a write that
    /// takes one second is still visible. A slower write is waited for (the bar holds just short of
    /// full); a failure stops the pacing at once.
    private func paced(_ first: Stage, _ write: @escaping @MainActor () async -> Void) async {
        pacing = true; paceVerify = false; paceDone = false
        defer { pacing = false }
        stage = first
        progress = 0
        let writer = Task { @MainActor in await write(); self.paceDone = true }
        func failed() -> Bool { paceDone && flashed == nil }
        let t0 = Date()
        while true {
            if failed() { await writer.value; return }
            let t = Date().timeIntervalSince(t0)
            let writeDone = paceDone || paceVerify
            if t >= 3 && writeDone { break }
            progress = min(writeDone ? 1 : 0.95, t / 3)
            try? await Task.sleep(for: .milliseconds(40))
        }
        progress = 1
        stage = .verify
        let t1 = Date()
        while !(paceDone && Date().timeIntervalSince(t1) >= 2) {
            if failed() { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        await writer.value
    }

    /// Read-only: read the iPod into ipod.bin and check which changes are on it.
    func readDeviceState() async {
        guard device != nil, !working else { return }
        begin([.read])
        defer { end() }
        guard let auth = await authorize(read: true, write: false,
                                          prompt: "Clickwheel wants to read your iPod's software to see which changes are on it. Nothing on the iPod is changed.") else { return }
        stage = .read
        progress = 0
        guard await readIntoLibrary(auth), let ds = deviceState else { return }
        let applied = patchIDs.filter { ds.patches[$0.rawValue] == "applied" }.map(\.rawValue)
        ok("on the iPod: " + (applied.isEmpty ? "Apple's original software (no changes)" : applied.joined(separator: " + ")))
        if ds.patches.values.contains("mismatch") { err("some patch locations hold unexpected bytes: not the supported firmware build") }
    }

    // MARK: what's on the iPod (from ipod.bin, the last read or verified write)

    struct DeviceState: Equatable {
        enum Source: String { case write, read }
        var patches: [String: String]     // patch -> original | applied | mismatch
        var source: Source
        var date: Date

        var applied: [String] { PatchID.allCases.map(\.rawValue).filter { patches[$0] == "applied" } }
        var isStock: Bool { PatchID.allCases.allSatisfy { (patches[$0.rawValue] ?? "original") == "original" } }
        var sourceText: String { source == .write ? "verified by read-back after writing" : "read from the iPod" }
    }

    /// Developer aid (demo mode): pretend the iPod has these patch states.
    var demoPatches: [String: String]?

    var deviceState: DeviceState? {
        let info = currentInfo
        if let p = demoPatches { return DeviceState(patches: p, source: .write, date: info?.date ?? Date()) }
        guard let c = check, c.ok, let p = c.patches else { return nil }
        return DeviceState(patches: p.mapValues(\.state), source: info?.source == "write" ? .write : .read, date: info?.date ?? .distantPast)
    }

    /// Patch states of the selection, as they would be on the iPod after writing it
    /// (builds use --exact, so a switch that is off means the original bytes).
    var selectionStates: [String: String] {
        Dictionary(uniqueKeysWithValues: patchIDs.map { p in
            // a picture another tool put on (state "custom") stays as it is
            (p.rawValue, selected.contains(p) ? (ownPicture.contains(p) ? "custom" : "applied") : isCustom(p) ? "custom" : "original")
        })
    }
    /// The iPod has a picture there that another tool (e.g. iPodWizard) put on: Clickwheel leaves it alone.
    func isCustom(_ p: PatchID) -> Bool { deviceState?.patches[p.rawValue] == "custom" && !p.ownPictureOptional(on: model) }

    var selectionIsInstalled: Bool {
        guard let d = deviceState, !d.patches.isEmpty else { return false }
        if patchIDs.contains(where: { selected.contains($0) && newPicture($0) }) { return false }
        return patchIDs.allSatisfy { d.patches[$0.rawValue] == selectionStates[$0.rawValue] }
    }

    // MARK: phase

    var phase: Phase {
        guard scannedOnce else { return .searching }
        guard let d = device else { return .connect }
        guard let m = d.model else {
            return .unsupported(d.board == nil
                ? "Clickwheel can't read this iPod's details. Open the iPod in Finder (so it shows up there), and Clickwheel will look again."
                : "This iPod (\(d.board!)) isn't one Clickwheel can change.")
        }
        if d.firmwareMatches == false {
            return .unsupported("This \(m.displayName) runs software version \(d.firmwareVersion ?? "?"). Clickwheel only works with version \(m.firmware.split(separator: " ").first ?? ""). Your iPod was not changed.")
        }
        if let c = check, c.ok, c.patchable != true {
            return .unsupported("This iPod's software isn't the exact version the changes were made for, so Clickwheel won't touch it. Your iPod was not changed.")
        }
        return .ready
    }

    /// True while ipod.bin exists but hasn't been checked by patch.py yet.
    var checking: Bool {
        guard let c = current else { return false }
        return check == nil && FileManager.default.fileExists(atPath: c.path)
    }

    var canApply: Bool {
        phase == .ready && !working && !checking && (hasPending || !selectionIsInstalled)
    }

    /// What the selection changes compared with the iPod (nil when the iPod's state isn't known).
    var selectionChanges: (add: [PatchID], remove: [PatchID])? {
        guard let d = deviceState, !d.patches.isEmpty else { return nil }
        let want = selectionStates
        return (patchIDs.filter { selected.contains($0) && (d.patches[$0.rawValue] != want[$0.rawValue] || newPicture($0)) },
                patchIDs.filter { !selected.contains($0) && ["applied", "custom"].contains(d.patches[$0.rawValue]) && !isCustom($0) })
    }
}
