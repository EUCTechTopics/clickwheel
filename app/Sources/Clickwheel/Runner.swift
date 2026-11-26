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

    /// Run a program with `fd` as its stdin (e.g. a device handle from AuthOpen), reporting each output
    /// line as it arrives. The descriptor is not closed; the caller still owns it.
    static func run(_ exe: String, _ args: [String], cwd: URL, stdin fd: Int32,
                    onLine: @escaping @Sendable (String) -> Void) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = cwd
                p.standardInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let out = Pipe()
                p.standardOutput = out; p.standardError = out
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stdout: "", stderr: "\(error)"))
                    return
                }
                var all = Data(), pending = Data()
                let h = out.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    all.append(chunk); pending.append(chunk)
                    while let nl = pending.firstIndex(of: 10) {
                        onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                        pending = Data(pending[(nl + 1)...])
                    }
                }
                p.waitUntilExit()
                cont.resume(returning: RunResult(status: p.terminationStatus,
                                                 stdout: String(decoding: all, as: UTF8.self), stderr: ""))
            }
        }
    }
}
