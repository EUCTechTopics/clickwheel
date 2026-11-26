import Foundation
import AppKit

struct RunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
    var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum Runner {
    /// Run a program without a shell. Never used for anything that writes to a device.
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = cwd }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stdout: "", stderr: "\(error)"))
                    return
                }
                // Read before waiting so large outputs can't fill the pipe and block.
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: RunResult(status: p.terminationStatus,
                                                 stdout: String(decoding: o, as: UTF8.self),
                                                 stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    static func showTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run one of the repo's sudo scripts in a Terminal window, exactly as the user would type it
    /// (`sudo scripts/….sh …`). The user enters their password in Terminal; the app never sees it.
    /// Raw disk access works from Terminal, while macOS blocks it for commands an app starts through
    /// `do shell script … with administrator privileges`.
    /// The output is mirrored to a log file that this function polls until the script has finished.
    /// Returns nil if the wait was cancelled (the Terminal window keeps whatever it was doing).
    static func runInTerminal(_ command: [String], cwd: URL, title: String,
                              progress: @escaping @MainActor (String) -> Void = { _ in }) async -> RunResult? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Clickwheel-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("output.log")
        let done = dir.appendingPathComponent("status")
        let script = dir.appendingPathComponent("clickwheel.command")
        let cmdline = "sudo " + command.map(shellQuote).joined(separator: " ")
        let body = """
        #!/bin/zsh
        cd \(shellQuote(cwd.path)) || exit 1
        clear
        print -P "%B== Clickwheel: \(title) ==%b"
        print "This window was opened by Clickwheel. It runs one command from the repository:"
        print
        print -P "%B$ \(cmdline.replacingOccurrences(of: "%", with: "%%"))%b"
        print
        print "sudo asks for your Mac password (typing is invisible)."
        print
        \(cmdline) 2>&1 | tee \(shellQuote(log.path))
        echo ${pipestatus[1]} > \(shellQuote(done.path))
        print
        print "Done. Clickwheel has the result; you can close this window."
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return RunResult(status: -1, stdout: "", stderr: "could not prepare the Terminal script: \(error)")
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let opened: Bool = await withCheckedContinuation { cont in
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                cont.resume(returning: err == nil)
            }
        }
        guard opened else { return RunResult(status: -1, stdout: "", stderr: "could not open Terminal") }
        while !Task.isCancelled {
            if let s = try? String(contentsOf: done, encoding: .utf8), let code = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let out = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                try? fm.removeItem(at: dir)
                return RunResult(status: code, stdout: out, stderr: "")
            }
            if let partial = try? String(contentsOf: log, encoding: .utf8) { await progress(partial) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }
}
