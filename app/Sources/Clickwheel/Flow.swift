import SwiftUI

/// Shown while a sudo script runs in Terminal: what to do, the exact command, and a live mirror of
/// the Terminal output, so the hand-off doesn't feel like the app froze.
struct TerminalPanel: View {
    @Environment(AppState.self) private var state
    var session: AppState.TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                    Text(">_").font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(Theme.phosphorOnDark)
                }
                .frame(width: 54, height: 54)
                .shadow(color: Theme.phosphorOnDark.opacity(0.35), radius: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.title2.weight(.semibold))
                    Text("Continue in the Terminal window: type your Mac password there and press Return. Typing is invisible. Clickwheel picks up the result by itself.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text("$").foregroundStyle(Theme.phosphorOnDark)
                Text(session.command).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .font(Theme.monoSmall)
            .padding(10)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "waiting for sudo…" : session.output)
                        .font(Theme.monoSmall)
                        .foregroundStyle(session.output.isEmpty ? Theme.phosphorOnDark.opacity(0.5) : Theme.phosphorOnDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("end")
                }
                .frame(height: 170)
                .background(Color(red: 0.04, green: 0.06, blue: 0.05), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: session.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }

            HStack {
                TimelineView(.periodic(from: session.started, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(session.started))
                    HStack(spacing: 6) {
                        LED(color: .accentColor, pulsing: true)
                        Text(String(format: "waiting %d:%02d", s / 60, s % 60)).font(Theme.monoSmall).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Stop Waiting") { state.stopWaiting() }
                    .help("Stop waiting; the command in Terminal is not interrupted")
                Button("Show Terminal", systemImage: "terminal") { Runner.showTerminal() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// After a successful write: a short, tickable reboot-and-test checklist.
struct TestChecklist: View {
    @Environment(AppState.self) private var state
    @State private var done: Set<Int> = []

    private var items: [(String, String)] {
        let label = state.selected.contains(.labels) ? "Labels" : "Genres"
        let next = state.selected.contains(.composers) ? (state.selected.contains(.producers) ? "Producers" : "Composers") : "Artists"
        var list = [
            ("eject", "Eject the iPod, then unplug it"),
            ("power", "Hold **Menu + Select** until the Apple logo appears"),
            ("music.note.list", "Open Music ▸ **\(label)**"),
            ("arrow.turn.down.right", "Pick a \(label == "Labels" ? "label" : "genre"): you see its **\(next)**, then albums, then songs"),
        ]
        if state.selected.contains(.producers) {
            list.append(("person.2", "Music ▸ **Producers** lists what used to be Composers"))
        }
        list.append(("checkmark.circle", "Music ▸ Artists still behaves as before"))
        return list
    }

    var body: some View {
        Card(title: "Reboot and test", symbol: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    Button {
                        withAnimation(.snappy) { if done.contains(i) { done.remove(i) } else { done.insert(i) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: done.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done.contains(i) ? Theme.phosphor : .secondary)
                                .font(.title3)
                            Image(systemName: it.0).frame(width: 20).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(it.1))
                                .strikethrough(done.contains(i), color: .secondary)
                                .foregroundStyle(done.contains(i) ? .secondary : .primary)
                            Spacer()
                            if i == 0 && state.device != nil {
                                Button("Eject", systemImage: "eject.fill") { Task { await state.eject() } }
                                    .controlSize(.small)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if done.count == items.count {
                Callout(kind: .ok, text: "All checked. Enjoy your patched iPod. If anything is off, Restore ▸ Roll Back puts the original firmware back.")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

/// One-line "what's on this iPod" summary, remembered per iPod.
struct InstalledBadge: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if let i = state.installed {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.phosphor)
                Text("On this iPod: ").foregroundStyle(.secondary)
                + Text(i.patches.joined(separator: " + ")).bold()
                Spacer()
                Text("written \(i.date.formatted(date: .abbreviated, time: .shortened))").font(Theme.monoTiny).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(10)
            .background(Theme.phosphor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.phosphor.opacity(0.25), lineWidth: 0.5))
        }
    }
}
