import SwiftUI

/// What the iPod's menus will look like, as an animated walk through the browse path.
struct IPodPreview: View {
    var model: IPodModel?
    var patches: Set<PatchID>
    var patched: Bool

    @State private var screen = 0
    @State private var bodyDark = false
    /// Selection per screen once the user scrolls the wheel; autoplay pauses after interaction.
    @State private var selection: [Int: Int] = [:]
    @State private var touched = Date.distantPast
    @State private var lastAngle: Double?
    @State private var turned: Double = 0

    private func sel(_ i: Int) -> Int { selection[i] ?? screens[i].sel }

    private var genre: String { patched && patches.contains(.labels) ? "Labels" : "Genres" }
    private var composer: String { patched && patches.contains(.producers) ? "Producers" : "Composers" }
    private var drillsToComposers: Bool { patched && patches.contains(.composers) }

    struct Screen { let title: String; let items: [String]; let sel: Int }

    private var screens: [Screen] {
        let second = drillsToComposers
            ? ["All", "Aphex Twin", "Boards of Canada", "Squarepusher", "Plaid"]
            : ["All", "Aphex Twin", "Boards of Canada", "Squarepusher feat. …", "Plaid & Mira Calix"]
        return [
            Screen(title: "Music", items: ["Playlists", "Artists", "Albums", "Songs", genre, composer, "Audiobooks"], sel: 4),
            Screen(title: genre, items: ["All", "Blue Note", "ECM", "Warp", "XL Recordings"], sel: 3),
            Screen(title: "Warp", items: second, sel: 2),
            Screen(title: "Boards of Canada", items: ["All", "Geogaddi", "Music Has the Right…", "Tomorrow's Harvest"], sel: 1),
        ]
    }

    var path: [String] {
        ["Music", genre, "Warp", drillsToComposers ? composer : "Artists", "Albums"]
    }

    var body: some View {
        VStack(spacing: 14) {
            device
                .frame(width: 210, height: 340)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            // breadcrumb of the browse path
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(p)
                        .foregroundStyle(i == min(screen + 1, path.count - 1) ? Color.primary : .secondary)
                        .fontWeight(highlight(p) ? .bold : .regular)
                        .foregroundStyle(highlight(p) ? Theme.phosphor : .secondary)
                }
            }
            .font(Theme.monoTiny)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text("drag wheel · click · MENU = back")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .task(id: patched) {
            screen = 0
            selection = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.9))
                guard Date().timeIntervalSince(touched) > 8 else { continue }  // the user is driving
                withAnimation(.snappy(duration: 0.35)) { screen = (screen + 1) % 4; selection = [:] }
            }
        }
    }

    private func highlight(_ p: String) -> Bool {
        patched && ((p == "Labels") || (p == "Producers") || (drillsToComposers && p == composer))
    }

    // MARK: device drawing

    private var dark: Bool { model == .g5 && bodyDark }

    private var device: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                // body
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: dark ? [Color(white: 0.20), Color(white: 0.06)] : [Color(white: 0.99), Color(white: 0.88)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                VStack(spacing: h * 0.07) {
                    lcd
                        .frame(width: w * 0.80, height: h * 0.36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.55), lineWidth: 2))
                    wheel(size: w * 0.72)
                }
                .padding(.top, h * 0.07)
            }
        }
        .onTapGesture { if model == .g5 { withAnimation { bodyDark.toggle() } } }
    }

    private var lcd: some View {
        let color = model?.colorScreen ?? true
        let s = screens[screen]
        return ZStack(alignment: .top) {
            (color ? Color.white : Color(red: 0.70, green: 0.76, blue: 0.70))
            VStack(spacing: 0) {
                // title bar
                ZStack {
                    if color {
                        LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)], startPoint: .top, endPoint: .bottom)
                    }
                    HStack {
                        Image(systemName: "play.fill").font(.system(size: 6)).opacity(0.7)
                        Spacer()
                        Image(systemName: "battery.75percent").font(.system(size: 9))
                    }
                    .padding(.horizontal, 5)
                    Text(s.title).font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                }
                .frame(height: 17)
                .foregroundStyle(.black)
                Rectangle().fill(.black.opacity(color ? 0.25 : 0.7)).frame(height: color ? 0.5 : 1)
                // rows
                VStack(spacing: 0) {
                    ForEach(Array(s.items.enumerated()), id: \.offset) { i, item in
                        HStack {
                            Text(item).font(.system(size: 10.5, weight: i == sel(screen) ? .semibold : .regular)).lineLimit(1)
                            Spacer()
                            if s.title == "Music" || i > 0 || s.title != "Boards of Canada" {
                                Image(systemName: "chevron.right").font(.system(size: 7, weight: .heavy))
                            }
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 15.5)
                        .foregroundStyle(i == sel(screen) ? .white : .black)
                        .background {
                            if i == sel(screen) {
                                if color {
                                    LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 1.0), Color(red: 0.05, green: 0.36, blue: 0.85)],
                                                   startPoint: .top, endPoint: .bottom)
                                } else {
                                    Color.black.opacity(0.85)
                                }
                            }
                        }
                    }
                }
                .id(screen)
                .transition(.push(from: .trailing))
            }
        }
    }

    private func click() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func scroll(_ d: Int) {
        let n = screens[screen].items.count
        let new = max(0, min(n - 1, sel(screen) + d))
        guard new != sel(screen) else { return }
        touched = Date()
        withAnimation(.easeOut(duration: 0.08)) { selection[screen] = new }
        click()
    }

    private func go(_ d: Int) {
        let target = screen + d
        guard (0..<screens.count).contains(target) else { return }
        touched = Date()
        withAnimation(.snappy(duration: 0.3)) { screen = target }
        click()
    }

    /// Circular drag on the wheel: every 24° of rotation moves the selection by one row.
    private func wheelDrag(size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let c = CGPoint(x: size / 2, y: size / 2)
                let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x)) * 180 / .pi
                if let last = lastAngle {
                    var delta = a - last
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    turned += delta
                    while turned >= 24 { turned -= 24; scroll(1) }
                    while turned <= -24 { turned += 24; scroll(-1) }
                }
                lastAngle = a
            }
            .onEnded { _ in lastAngle = nil; turned = 0 }
    }

    private func wheel(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(dark ? AnyShapeStyle(Color(white: 0.12)) : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
            Circle()
                .fill(dark ? Color(white: 0.18) : Color(white: 0.97))
                .frame(width: size * 0.38)
                .contentShape(Circle())
                .onTapGesture { go(1) }
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            Group {
                Text("MENU").font(.system(size: 9.5, weight: .bold))
                    .padding(8).contentShape(Rectangle())
                    .onTapGesture { go(-1) }
                    .offset(y: -size * 0.37)
                Image(systemName: "backward.end.alt.fill").font(.system(size: 8)).offset(x: -size * 0.37)
                Image(systemName: "forward.end.alt.fill").font(.system(size: 8)).offset(x: size * 0.37)
                Image(systemName: "playpause.fill").font(.system(size: 8)).offset(y: size * 0.37)
            }
            .foregroundStyle(dark ? Color(white: 0.7) : Color(white: 0.55))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .simultaneousGesture(wheelDrag(size: size))
    }
}

/// The right-hand inspector: preview + a stock/patched switch + the model "label plate".
struct PreviewPanel: View {
    @Environment(AppState.self) private var state
    @State private var showPatched = true

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $showPatched) {
                Text("Stock").tag(false)
                Text("Patched").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            IPodPreview(model: state.model, patches: state.selected, patched: showPatched)

            VStack(alignment: .leading, spacing: 5) {
                SpecRow(key: "model", value: state.device?.modelNumber ?? (state.model == nil ? "no iPod" : "—"))
                SpecRow(key: "board", value: state.device?.board ?? "—")
                SpecRow(key: "firmware", value: state.device?.firmwareVersion ?? state.model?.firmware ?? "—")
                SpecRow(key: "patches", value: state.selected.isEmpty ? "none" : PatchID.allCases.filter { state.selected.contains($0) }.map { String($0.rawValue.prefix(3)) }.joined(separator: "+"))
                if let c = state.check?.osos?.checksum {
                    SpecRow(key: "sum", value: hex32(c))
                    if let n = state.plan?.new_checksum { SpecRow(key: "sum'", value: hex32(n), valueColor: Theme.phosphor) }
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
        .padding(.top, 20)
        .padding(.horizontal, 14)
    }
}
