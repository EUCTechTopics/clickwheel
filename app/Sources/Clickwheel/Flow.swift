import SwiftUI

/// What's on the connected iPod: per patch installed / not installed, with where that knowledge
/// comes from, and a read-only "Read from iPod" check.
struct DeviceStateCard: View {
    @Environment(AppState.self) private var state
    var compact = false

    var body: some View {
        Card(title: "On this iPod", symbol: "ipod") {
            if let ds = state.deviceState, !ds.patches.isEmpty {
                if compact {
                    HStack(spacing: 8) {
                        ForEach(state.patchIDs) { p in chip(p, ds.patches[p.rawValue]) }
                        Spacer()
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(state.patchIDs) { p in
                            HStack(spacing: 10) {
                                Image(systemName: p.symbol).foregroundStyle(.secondary).frame(width: 22)
                                Text(p.title)
                                Spacer()
                                chip(p, ds.patches[p.rawValue])
                            }
                        }
                    }
                }
                footer(ds)
            } else {
                Text("Not known yet. Clickwheel learns it every time it reads or writes the iPod.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer(nil)
            }
        }
    }

    private func chip(_ p: PatchID, _ s: String?) -> some View {
        let (text, color): (String, Color) = switch s {
        case "applied": (compact ? p.rawValue : "installed", Theme.phosphor)
        case "original": (compact ? p.rawValue : "not installed", .secondary)
        case "mismatch": (compact ? p.rawValue : "unknown bytes", .red)
        default: (compact ? p.rawValue : "unknown", .secondary)
        }
        return HStack(spacing: 4) {
            if compact { Image(systemName: s == "applied" ? "checkmark" : "minus").font(.system(size: 8, weight: .bold)) }
            Text(text.uppercased())
        }
        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        .tracking(0.6)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(s == "applied" ? 0.16 : 0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }

    private func footer(_ ds: AppState.DeviceState?) -> some View {
        HStack(spacing: 8) {
            if let ds {
                Image(systemName: "checkmark.shield").foregroundStyle(Theme.phosphor)
                Text("\(ds.sourceText) · \(ds.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.monoTiny).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Read from iPod…", systemImage: "arrow.down.doc.fill") { Task { await state.readDeviceState() } }
                .controlSize(.small)
                .disabled(state.working || state.device == nil)
                .help("Read-only: reads the firmware partition (asks for your Mac password) and checks every patch location")
        }
    }
}
