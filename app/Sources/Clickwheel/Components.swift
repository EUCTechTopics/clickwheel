import SwiftUI
import AppKit

enum Theme {
    /// Phosphor green for live readouts; amber for warnings. Everything else uses system colors.
    /// Adapts to the appearance: bright on dark, a deeper green/orange on light for contrast.
    static let phosphor = dynamic(dark: NSColor(red: 0.30, green: 0.92, blue: 0.55, alpha: 1),
                                  light: NSColor(red: 0.04, green: 0.55, blue: 0.27, alpha: 1))
    static let amber = dynamic(dark: NSColor(red: 1.0, green: 0.72, blue: 0.22, alpha: 1),
                               light: NSColor(red: 0.80, green: 0.45, blue: 0.0, alpha: 1))
    /// For text on the always-dark console and terminal surfaces.
    static let phosphorOnDark = Color(red: 0.30, green: 0.92, blue: 0.55)

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let monoTiny = Font.system(size: 10, design: .monospaced)
}

extension StepStatus {
    var color: Color {
        switch self {
        case .todo: return .secondary.opacity(0.35)
        case .ready: return .accentColor
        case .done: return Theme.phosphor
        case .warn: return Theme.amber
        case .blocked: return .red
        }
    }
    var label: String {
        switch self {
        case .todo: return "waiting"
        case .ready: return "ready"
        case .done: return "done"
        case .warn: return "check"
        case .blocked: return "stopped"
        }
    }
}

/// A small glowing status LED.
struct LED: View {
    var color: Color
    var pulsing = false
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: on ? 4 : 2)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .opacity(pulsing && on ? 0.45 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true }
            }
    }
}

/// Section card used on every page.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// "key ........ value" row in monospace, like a spec sheet.
struct SpecRow: View {
    var key: String
    var value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Rectangle().fill(.separator).frame(height: 0.5).offset(y: -3)
            Text(value).foregroundStyle(valueColor).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
        }
        .font(Theme.monoSmall)
    }
}

/// Page header: big step number + title + one-line subtitle.
struct PageHeader: View {
    var step: Step
    var subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(step.number)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.largeTitle.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

struct Callout: View {
    enum Kind { case info, warn, danger, ok }
    var kind: Kind
    var text: LocalizedStringKey
    var body: some View {
        let (sym, color): (String, Color) = switch kind {
        case .info: ("info.circle.fill", .accentColor)
        case .warn: ("exclamationmark.triangle.fill", Theme.amber)
        case .danger: ("exclamationmark.octagon.fill", .red)
        case .ok: ("checkmark.seal.fill", Theme.phosphor)
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sym).foregroundStyle(color).font(.title3)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }
}

/// Partition map: a 1-D view of the firmware partition with images and patch locations.
struct PartitionMap: View {
    var size: Int
    var images: [PatchReport.Image]
    var marks: [Int]
    var checksumOffset: Int?

    private func color(_ t: String) -> Color {
        switch t {
        case "osos": return .accentColor
        case "aupd": return .purple
        case "rsrc": return .teal
        case "hibe": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(max(size, 1)) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6))
                    // header + directory
                    Rectangle().fill(.orange.opacity(0.8)).frame(width: max(2, x(0x4600)))
                    ForEach(Array(images.enumerated()), id: \.offset) { _, im in
                        Rectangle()
                            .fill(color(im.type).gradient.opacity(0.75))
                            .frame(width: max(2, x(im.length)))
                            .offset(x: x(im.offset))
                    }
                    ForEach(marks, id: \.self) { m in
                        Rectangle().fill(Theme.phosphor).frame(width: 1.5).offset(x: x(m))
                            .shadow(color: Theme.phosphor, radius: 3)
                    }
                    if let c = checksumOffset {
                        Rectangle().fill(Theme.amber).frame(width: 1.5).offset(x: x(c))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 22)
            HStack(spacing: 12) {
                legend(.orange, "hdr+dir")
                ForEach(Array(images.enumerated()), id: \.offset) { _, im in
                    legend(color(im.type), "\(im.type) \(hex(im.offset))")
                }
                Spacer()
                legend(Theme.phosphor, "patch")
                legend(Theme.amber, "checksum")
            }
            .font(Theme.monoTiny)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8); Text(t) }
    }
}

/// Byte-level diff of the planned changes, grouped into runs.
struct HexDiff: View {
    var changes: [PatchReport.Change]

    struct Run: Identifiable {
        let id: Int
        var old: [UInt8] = []
        var new: [UInt8] = []
    }

    var runs: [Run] {
        var out: [Run] = []
        for c in changes.sorted(by: { $0.offset < $1.offset }) {
            if var last = out.last, last.id + last.old.count == c.offset {
                last.old.append(c.old); last.new.append(c.new); out[out.count - 1] = last
            } else {
                out.append(Run(id: c.offset, old: [c.old], new: [c.new]))
            }
        }
        return out
    }

    private func hexs(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private func ascii(_ b: [UInt8]) -> String { String(b.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "·" }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OFFSET").frame(width: 76, alignment: .leading)
                Text("OLD").frame(maxWidth: .infinity, alignment: .leading)
                Text("NEW").frame(maxWidth: .infinity, alignment: .leading)
                Text("ASCII").frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            Divider()
            ForEach(runs) { r in
                HStack(alignment: .firstTextBaseline) {
                    Text(hex(r.id)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                    Text(hexs(r.old)).foregroundStyle(.red.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(hexs(r.new)).foregroundStyle(Theme.phosphor).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(ascii(r.old)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(ascii(r.new))
                    }
                    .frame(width: 170, alignment: .leading)
                }
                .font(Theme.monoSmall)
                .padding(.vertical, 3)
                .textSelection(.enabled)
            }
        }
    }
}

/// Spinner + text for the busy state.
struct BusyLabel: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.monoSmall).foregroundStyle(.secondary)
        }
    }
}
