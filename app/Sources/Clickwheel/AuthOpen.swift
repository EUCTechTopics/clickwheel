import Foundation
import Security

/// Opens a raw disk partition through Apple's /usr/libexec/authopen, so no Terminal and no sudo are
/// needed. macOS shows its standard password dialog (with Clickwheel's text), and authopen hands back
/// an open file descriptor for that one device over a socket (SCM_RIGHTS), then exits. Clickwheel
/// never sees the password and never runs anything as root.
///
/// An `AuthSession` asks for the password once, for every access one operation needs (e.g. reading
/// to read the iPod and writing for the install), and can then open the device several times.
final class AuthSession: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case denied(OSStatus)
        case launch(String)
        case noDescriptor(String)

        var description: String {
            switch self {
            case .cancelled: return "cancelled at the password dialog"
            case .denied(let s): return "macOS refused the request (\(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "?"))"
            case .launch(let s): return "could not start authopen: \(s)"
            case .noDescriptor(let s): return "authopen returned no file handle\(s.isEmpty ? "" : ": " + s)"
            }
        }
    }

    let path: String
    private let auth: AuthorizationRef

    static func right(_ path: String, writable: Bool) -> String {
        "sys.openfile.\(writable ? "readwrite" : "readonly").\(path)"
    }

    /// Shows the password dialog once for the requested kinds of access to `path`.
    /// `preauthorize: false` skips the dialog; authopen then only opens what the user may open
    /// anyway (used to self-test the mechanism on an ordinary file).
    init(path: String, read: Bool, write: Bool, prompt: String, preauthorize: Bool = true) throws {
        self.path = path
        var ref: AuthorizationRef?
        var st = AuthorizationCreate(nil, nil, [], &ref)
        guard st == errAuthorizationSuccess, let ref else { throw Failure.denied(st) }
        auth = ref
        guard preauthorize else { return }

        let names = (read ? [Self.right(path, writable: false)] : []) + (write ? [Self.right(path, writable: true)] : [])
        let cNames = names.map { strdup($0)! }
        let cPrompt = strdup(prompt)!
        let cPromptKey = strdup(kAuthorizationEnvironmentPrompt)!
        defer { cNames.forEach { free($0) }; free(cPrompt); free(cPromptKey) }
        var items = cNames.map { AuthorizationItem(name: $0, valueLength: 0, value: nil, flags: 0) }
        var promptItem = AuthorizationItem(name: cPromptKey, valueLength: strlen(cPrompt), value: cPrompt, flags: 0)
        st = items.withUnsafeMutableBufferPointer { itemsPtr in
            withUnsafeMutablePointer(to: &promptItem) { promptPtr in
                var rights = AuthorizationRights(count: UInt32(itemsPtr.count), items: itemsPtr.baseAddress)
                var env = AuthorizationEnvironment(count: 1, items: promptPtr)
                return AuthorizationCopyRights(ref, &rights, &env, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        if st == errAuthorizationCanceled { throw Failure.cancelled }
        guard st == errAuthorizationSuccess else { throw Failure.denied(st) }
    }

    deinit { AuthorizationFree(auth, [.destroyRights]) }

    /// Asks for the password off the main thread.
    static func make(path: String, read: Bool, write: Bool, prompt: String) async throws -> AuthSession {
        try await Task.detached(priority: .userInitiated) {
            try AuthSession(path: path, read: read, write: write, prompt: prompt)
        }.value
    }

    /// A file descriptor for the session's path (no dialog; the access must have been authorized).
    /// The caller owns the descriptor and must close it.
    func open(writable: Bool) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) { try self.openBlocking(writable: writable) }.value
    }

    func openBlocking(writable: Bool) throws -> Int32 {
        var ext = AuthorizationExternalForm()
        let st = AuthorizationMakeExternalForm(auth, &ext)
        guard st == errAuthorizationSuccess else { throw Failure.denied(st) }

        // authopen sends the descriptor over its stdout, which must be a socket.
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { throw Failure.launch(String(cString: strerror(errno))) }
        let ours = sv[0], theirs = sv[1]
        defer { close(ours) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        p.arguments = ["-stdoutpipe", "-extauth", "-o", String(writable ? O_RDWR : O_RDONLY), path]
        let input = Pipe(), errors = Pipe()
        p.standardInput = input
        // closeOnDealloc must stay false: we close `theirs` below, and a second close when the
        // FileHandle is freed would hit whatever reuses that number (the descriptor we receive).
        p.standardOutput = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
        p.standardError = errors
        do { try p.run() } catch {
            close(theirs)
            throw Failure.launch("\(error)")
        }
        close(theirs)
        let extData = withUnsafeBytes(of: &ext) { Data($0) }
        input.fileHandleForWriting.write(extData)
        try? input.fileHandleForWriting.close()

        let fd = Self.receiveDescriptor(ours)
        p.waitUntilExit()
        let errText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fd else {
            throw Failure.noDescriptor(errText.isEmpty ? "exit status \(p.terminationStatus)" : errText)
        }
        return fd
    }

    /// Receives one descriptor sent with SCM_RIGHTS; nil if the other side closed without sending.
    private static func receiveDescriptor(_ sock: Int32) -> Int32? {
        var byte: UInt8 = 0
        let space = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 16
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, space)
        return withUnsafeMutablePointer(to: &byte) { bytePtr -> Int32? in
            var iov = iovec(iov_base: bytePtr, iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int32? in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPtr, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(space), msg_flags: 0)
                var n: Int
                repeat { n = recvmsg(sock, &msg, 0) } while n < 0 && errno == EINTR
                guard n > 0, msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return nil }
                let hdr = control.load(as: cmsghdr.self)
                guard hdr.cmsg_level == SOL_SOCKET, hdr.cmsg_type == SCM_RIGHTS else { return nil }
                // CMSG_DATA: the payload follows the header, aligned to 4 bytes on Darwin.
                let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
                return control.load(fromByteOffset: dataOffset, as: Int32.self)
            }
        }
    }
}
