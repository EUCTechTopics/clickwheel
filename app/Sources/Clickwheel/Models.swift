import Foundation

/// A supported iPod model. Mirrors MODELS in scripts/patch.py and the scripts in scripts/.
enum IPodModel: String, CaseIterable, Identifiable, Codable {
    case g4 = "4g"
    case photo = "photo"
    case g5 = "5g"
    /// iPod Video 5.5th gen: the 5G's firmware, laid out in 2048-byte sectors (160 MiB partition).
    case g55 = "55g"
    /// iPod nano 1st gen: a 64 MiB partition like the 5G's, told apart by its USB product ID (4618).
    case nano = "nano"

    var id: String { rawValue }
    /// Either iPod Video (5G or 5.5G): same firmware, screen and tweaks.
    var isVideo: Bool { self == .g5 || self == .g55 }

    var displayName: String {
        switch self {
        case .g4: return "iPod 4th generation"
        case .photo: return "iPod photo / color"
        case .g5: return "iPod Video (5th gen)"
        case .g55: return "iPod Video (5.5th gen)"
        case .nano: return "iPod nano (1st gen)"
        }
    }

    var board: String {
        switch self {
        case .g4: return "iPod Q21"
        case .photo: return "iPod P98"
        case .g5, .g55: return "iPod Video"
        case .nano: return "iPod nano"
        }
    }

    var firmware: String {
        switch self {
        case .g4: return "3.1.1"
        case .photo: return "1.2.1 (4.2.1)"
        case .g5, .g55: return "osos 0x735A00"
        case .nano: return "osos 0x54EF30"
        }
    }

    var partitionSize: Int { self == .g55 ? 167_772_160 : self == .g5 || self == .nano ? 67_108_864 : 33_554_432 }
    var backupFile: String {
        switch self {
        case .g4: return "ipod_fw_backup.bin"
        case .photo: return "ipodphoto_fw_backup.bin"
        case .g5: return "ipod5g_fw_backup.bin"
        case .g55: return "ipod55g_fw_backup.bin"
        case .nano: return "ipodnano_fw_backup.bin"
        }
    }
    var patchedFile: String {
        switch self {
        case .g4: return "ipod_fw_patched.bin"
        case .photo: return "ipodphoto_fw_patched.bin"
        case .g5: return "ipod5g_fw_patched.bin"
        case .g55: return "ipod55g_fw_patched.bin"
        case .nano: return "ipodnano_fw_patched.bin"
        }
    }
    var colorScreen: Bool { self != .g4 }
    /// Screen height in pixels (to show pictures at their real size on the preview).
    var screenHeight: CGFloat { isVideo ? 240 : self == .photo ? 176 : self == .nano ? 132 : 128 }
    /// Tested on a real device by the project.
    var deviceTested: Bool { true }
}

/// What the iPod preview next to the switches shows.
enum PreviewMode: String, CaseIterable, Identifiable {
    case menus = "Menus", startup = "Startup", connected = "Connected"
    var id: String { rawValue }
    /// The change whose picture this screen shows.
    var patch: PatchID? { self == .startup ? .logo : self == .connected ? .dnd : nil }
}

enum PatchID: String, CaseIterable, Identifiable {
    case labels, composers, producers, logo, dnd, volume
    var id: String { rawValue }
    /// Offered for this model? The boot logo and the DnD picture exist for the iPod photo / color and the iPod Video.
    func available(on model: IPodModel?) -> Bool {
        switch self {
        case .logo: return model == .photo || model == .nano || model?.isVideo == true
        case .dnd: return model == .photo || model?.isVideo == true
        default: return true
        }
    }
    /// Turning it on asks for a picture file (a BMP of `pictureSize`).
    var takesPicture: Bool { self == .dnd }
    /// The preview screen that shows this change.
    var previewMode: PreviewMode { self == .logo ? .startup : self == .dnd ? .connected : .menus }
    /// Option-click on the switch uses your own picture instead (the boot logo on the iPod photo and Video).
    func ownPictureOptional(on model: IPodModel?) -> Bool { self == .logo && (model == .photo || model == .nano || model?.isVideo == true) }
    /// Size of the BMP this change takes: the boot logo is 78×100 on the iPod photo, 62×78 on the iPod Video.
    func pictureSize(on model: IPodModel?) -> (width: Int, height: Int) {
        self == .logo ? (model?.isVideo == true || model == .nano ? (62, 78) : (78, 100)) : (100, 100)
    }
    /// patch.py option that takes the picture file (or "keep").
    var pictureFlag: String { self == .logo ? "--logo-image" : flag }
    var title: String {
        switch self {
        case .labels: return "Genres → Labels"
        case .composers: return "Label → Composers"
        case .producers: return "Composers → Producers"
        case .logo: return "Apple logo upside down"
        case .dnd: return "Own “Do not disconnect” picture"
        case .volume: return "No volume limit"
        }
    }
    var flag: String { "--\(rawValue)" }
    var symbol: String {
        switch self {
        case .labels: return "tag"
        case .composers: return "arrow.triangle.branch"
        case .producers: return "slider.horizontal.3"
        case .logo: return "apple.logo"
        case .dnd: return "photo"
        case .volume: return "speaker.wave.3"
        }
    }
    /// Plain-language wording for the main window.
    var plainTitle: String {
        switch self {
        case .labels: return "Rename Genres to Labels"
        case .composers: return "Open a label to see its composers"
        case .producers: return "Rename Composers to Producers"
        case .logo: return "Flip the Apple logo upside down"
        case .dnd: return "Use your own “Do not disconnect” picture"
        case .volume: return "Remove the volume limit"
        }
    }
    var plainBlurb: String {
        switch self {
        case .labels: return "For collections sorted by record label. The Genres menu is called Labels."
        case .composers: return "Picking a label (or genre) lists its composers, then albums, then songs. Normally it lists artists."
        case .producers: return "For people who keep the producer in the Composer field. The Composers menu is called Producers."
        case .logo: return "The Apple logo shown while the iPod starts up is upside down."
        case .dnd: return "Shown while the iPod is connected to the Mac. Turn it on to choose a 100×100 BMP picture."
        case .volume: return "Lifts the built-in (European) maximum volume. Then raise Settings → Volume Limit. Loud music can damage your hearing."
        }
    }
    var shortName: String {
        switch self {
        case .labels: return "Labels"
        case .composers: return "Composers per label"
        case .producers: return "Producers"
        case .logo: return "Upside-down logo"
        case .dnd: return "Own Do not disconnect picture"
        case .volume: return "No volume limit"
        }
    }
    var blurb: String {
        switch self {
        case .labels: return "Renames the English Genres menu to Labels (5 strings, same length)."
        case .composers: return "Picking a label opens its Composers instead of its Artists (1 bytecode operand)."
        case .producers: return "Renames the English Composers menu to Producers (5 strings, same length)."
        case .logo: return "Flips the boot logo, or puts your own BMP there, in the encrypted aupd image (same size); the iPod copies it into its boot ROM at the next start."
        case .dnd: return "Replaces the 100×100 picture (iPodWizard index 97 on the iPod photo, 372 on the iPod Video) with your BMP; Apple's original is saved first so it can be put back."
        case .volume: return "The volume-cap check (which sets the maximum to 216 instead of 256) always answers no: and r0, r0, #1 becomes #0 (2 bytes, checksum unchanged)."
        }
    }
}

/// A connected, Mac-formatted iPod as seen by diskutil and SysInfo.
struct Device: Equatable {
    var disk: String            // disk4
    var partition: String       // disk4s2
    var partitionSize: Int
    var volumeName: String?
    var mountPoint: String?
    var sysInfo: [String: String]
    var capacity: Int? = nil    // whole disk, bytes
    /// USB product ID (4617 iPod Video, 4618 iPod nano 1G), to tell same-size partitions apart.
    var usbProduct: Int? = nil

    var board: String? { sysInfo["BoardHwName"] }
    var modelNumber: String? { sysInfo["ModelNumStr"] }
    var serial: String? { sysInfo["pszSerialNumber"] }
    var buildID: String? { sysInfo["buildID"] }
    var visibleBuildID: String? { sysInfo["visibleBuildID"] }

    /// "0x01218000 (1.2.1)" -> "1.2.1"
    static func version(_ s: String?) -> String? {
        guard let s, let a = s.firstIndex(of: "("), let b = s.firstIndex(of: ")"), a < b else { return s }
        return String(s[s.index(after: a)..<b])
    }
    var firmwareVersion: String? { Self.version(visibleBuildID) }
    var buildVersion: String? { Self.version(buildID) }

    /// Same rules as scripts/ipod_model.sh.
    var model: IPodModel? {
        switch board {
        case "iPod Q21": return .g4
        case "iPod P98": return .photo
        case nil, "":
            if partitionSize == 67_108_864 { return usbProduct == 4618 ? .nano : .g5 }
            return partitionSize == 167_772_160 ? .g55 : nil
        default: return nil
        }
    }

    /// Firmware version check from SysInfo, where we can tell.
    var firmwareMatches: Bool? {
        guard let model, let b = buildID else { return nil }
        switch model {
        case .g4: return b.contains("(3.1.1)")
        case .photo: return b.contains("(4.2.1)")
        case .g5, .g55, .nano: return nil
        }
    }
}

// MARK: - patch.py --json reports

/// scripts/library.py: the iPod's own music, per genre (= label), for the preview.
struct LibraryReport: Decodable {
    struct Person: Decodable, Equatable { let name: String; let albums: [String] }
    struct Genre: Decodable, Equatable { let name: String; let songs: Int; let composers: [Person]; let artists: [Person] }
    struct Song: Decodable, Equatable, Hashable {
        let title: String
        var artist: String? = nil, composer: String? = nil, album: String? = nil, genre: String? = nil
        var track: Int? = nil, disc: Int? = nil
    }
    let ok: Bool
    let genres: [Genre]?
    /// Every song (also those without a genre), for the Songs menu and album lists.
    let songs: [Song]?
}

struct PatchReport: Decodable {
    struct Osos: Decodable { let offset: Int; let length: Int; let checksum: UInt32; let stock: Bool? }
    struct Edit: Decodable { let offset: Int; let old: String; let new: String }
    struct Patch: Decodable { let state: String; let desc: String; let edits: [Edit] }
    struct Image: Decodable { let type: String; let offset: Int; let length: Int }
    struct Change: Decodable { let offset: Int; let old: UInt8; let new: UInt8 }

    let ok: Bool
    let error: String?
    let model: String?
    let name: String?
    let input: String?
    let sha256: String?
    let osos: Osos?
    let checksum_offset: Int?
    let part_size: Int?
    let images: [Image]?
    let patches: [String: Patch]?
    let patchable: Bool?
    // plan / build
    let applied: [String]?
    let removed: [String]?
    let result_states: [String: String]?
    let result_stock: Bool?
    let new_checksum: UInt32?
    let output: String?
    let output_sha256: String?
    let sectors: [Int]?
    let changes: [Change]?
    /// Pictures of the result (boot logo, DnD) as BMP files, from `--preview`.
    let previews: [String: String]?
}

extension Data {
    init?(hex: String) {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}

func hex(_ v: Int, width: Int = 6) -> String {
    "0x" + String(String(v, radix: 16, uppercase: true).leftPad(width))
}
func hex32(_ v: UInt32) -> String { "0x" + String(String(v, radix: 16, uppercase: true).leftPad(8)) }

extension String {
    func leftPad(_ n: Int, with c: Character = "0") -> String {
        count >= n ? self : String(repeating: c, count: n - count) + self
    }
}
