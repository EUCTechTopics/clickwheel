import SwiftUI

/// What the iPod's menus will look like, as an animated walk through the browse path.
struct IPodPreview: View {
    var model: IPodModel?
    var patches: Set<PatchID>
    var patched: Bool
    /// Menus, or the boot logo / "Do not disconnect" picture as they will be.
    var mode: PreviewMode = .menus
    var picture: NSImage?
    /// The iPod's own music; examples are used when it can't be read.
    var music: [LibraryReport.Genre]?

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
    /// Rows the screen shows at once; longer lists scroll with the selection.
    static let rows = 6

    /// Example music when the iPod's own library isn't available.
    private static let examples: [LibraryReport.Genre] = {
        typealias P = LibraryReport.Person
        return [
            .init(name: "Ninja Tune", songs: 40,
                  composers: [P(name: "Simon Green", albums: ["Fragments", "Migration", "The North Borders", "Black Sands"]),
                              P(name: "Jason Swinscoe", albums: ["To Believe", "Ma Fleur"]),
                              P(name: "Jordan Rakei", albums: ["Origin", "Wallflower"]),
                              P(name: "Thomas Fehlmann", albums: ["Gute Luft"])],
                  artists: [P(name: "Bonobo", albums: ["Fragments", "Migration", "The North Borders", "Black Sands"]),
                            P(name: "The Cinematic Orchestra", albums: ["To Believe", "Ma Fleur"]),
                            P(name: "Jordan Rakei", albums: ["Origin", "Wallflower"]),
                            P(name: "Bonobo feat. Jamila Woods", albums: ["Fragments"])]),
            .init(name: "Rough Trade", songs: 30, composers: [], artists: []),
            .init(name: "Sub Pop", songs: 20, composers: [], artists: []),
            .init(name: "XL Recordings", songs: 10, composers: [], artists: []),
        ]
    }()

    // The walk follows the wheel: each list is built from what's selected on the screen before it.
    /// Sorted like the iPod: case-insensitive, ignoring a leading "The ".
    private static func sortKey(_ s: String) -> String {
        let l = s.lowercased()
        return l.hasPrefix("the ") ? String(l.dropFirst(4)) : l
    }
    private static func sorted(_ a: [String]) -> [String] {
        a.sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
    }

    private var labels: [LibraryReport.Genre] {
        let all = (music?.isEmpty == false) ? music! : Self.examples
        let order = Self.sorted(all.map(\.name))
        return all.sorted { order.firstIndex(of: $0.name)! < order.firstIndex(of: $1.name)! }
    }
    /// Default label for the autoplay: the biggest one with several composers.
    private var defaultLabel: Int {
        let ls = labels
        let best = ls.filter { $0.composers.count >= 2 && !$0.artists.isEmpty }.max { $0.songs < $1.songs }
            ?? ls.max { $0.songs < $1.songs }
        return best.flatMap { b in ls.firstIndex { $0.name == b.name } } ?? 0
    }
    private var labelRow: Int { selection[1] ?? defaultLabel + 1 }          // 0 = All
    private var people: [LibraryReport.Person] {
        let gs = labelRow == 0 ? labels : [labels[min(labelRow - 1, labels.count - 1)]]
        var merged: [(name: String, albums: [String])] = []
        for g in gs {
            for p in drillsToComposers ? g.composers : g.artists {
                if let i = merged.firstIndex(where: { $0.name == p.name }) {
                    merged[i].albums += p.albums.filter { !merged[i].albums.contains($0) }
                } else {
                    merged.append((p.name, p.albums))
                }
            }
        }
        let order = Self.sorted(merged.map(\.name))
        return merged.sorted { order.firstIndex(of: $0.name)! < order.firstIndex(of: $1.name)! }
            .map { LibraryReport.Person(name: $0.name, albums: Self.sorted($0.albums)) }
    }
    private var defaultPerson: Int {
        let ps = people
        return ps.indices.max { ps[$0].albums.count < ps[$1].albums.count } ?? 0
    }
    private var personRow: Int { selection[2] ?? (people.isEmpty ? 0 : defaultPerson + 1) }
    private var albums: [String] {
        let ps = people
        if ps.isEmpty { return [] }
        if personRow == 0 { return Self.sorted(Array(Set(ps.flatMap(\.albums)))) }
        return ps[min(personRow - 1, ps.count - 1)].albums
    }

    private var screens: [Screen] {
        let ls = labels, ps = people, al = albums
        return [
            Screen(title: "Music", items: ["Playlists", "Artists", "Albums", "Songs", genre, composer], sel: 4),
            Screen(title: genre, items: ["All"] + ls.map(\.name), sel: defaultLabel + 1),
            Screen(title: labelRow == 0 ? genre : ls[min(labelRow - 1, ls.count - 1)].name,
                   items: ["All"] + ps.map(\.name), sel: ps.isEmpty ? 0 : defaultPerson + 1),
            Screen(title: personRow == 0 || ps.isEmpty ? (drillsToComposers ? composer : "Artists") : ps[min(personRow - 1, ps.count - 1)].name,
                   items: ["All"] + al, sel: al.isEmpty ? 0 : 1),
        ]
    }

    /// The browse path, without the example label the screens open.
    var path: [String] {
        ["Music", genre, drillsToComposers ? composer : "Artists", "Albums"]
    }

    var body: some View {
        VStack(spacing: 14) {
            device
                .frame(width: 210, height: 340)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            // breadcrumb of the browse path
            if mode == .menus { breadcrumb }
        }
        // Switching a change keeps the place in the walk, so the difference shows where you are.
        .onChange(of: drillsToComposers) {
            touched = Date()                                     // hold the autoplay a moment
            withAnimation(.easeInOut(duration: 0.2)) {
                for k in selection.keys where k >= 2 { selection[k] = nil }   // artists <-> composers
                if screen > 2 { screen = 2 }                     // that person may not be in the other list
            }
        }
        .onChange(of: patches) { touched = Date() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.9))
                guard mode == .menus, Date().timeIntervalSince(touched) > 8 else { continue }  // the user is driving
                withAnimation(.snappy(duration: 0.35)) { screen = (screen + 1) % 4; selection = [:] }
            }
        }
    }

    private var breadcrumb: some View {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(p)
                        .foregroundStyle(i == [1, 1, 2, 3][screen] ? Color.primary : .secondary)
                        .fontWeight(highlight(p) ? .bold : .regular)
                        .foregroundStyle(highlight(p) ? Theme.phosphor : .secondary)
                }
            }
            .font(Theme.monoTiny)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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

    @ViewBuilder private var lcd: some View {
        switch mode {
        case .menus: menuLCD
        case .startup: pictureLCD(background: .black, text: nil)
        case .connected: pictureLCD(background: .white, text: "Do not disconnect.")
        }
    }

    /// A picture at its real size on the iPod's screen (scaled with the screen), e.g. the boot logo.
    private func pictureLCD(background: Color, text: String?) -> some View {
        GeometryReader { g in
            let scale = g.size.height / (model?.screenHeight ?? 240)
            ZStack {
                background
                if let img = picture, let rep = img.representations.first {
                    VStack(spacing: 8 * scale) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
                        if let text {
                            Text(text).font(.system(size: 15 * scale, weight: .semibold)).foregroundStyle(.black)
                        }
                    }
                } else {
                    Text("Connect your iPod to see this picture")
                        .font(.system(size: 9)).multilineTextAlignment(.center)
                        .foregroundStyle(background == .black ? Color(white: 0.6) : .gray)
                        .padding(10)
                }
            }
        }
        .transition(.opacity)
    }

    private var menuLCD: some View {
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
                    let first = max(0, min(sel(screen) - (Self.rows - 1), s.items.count - Self.rows))
                    ForEach(Array(s.items.enumerated()).filter { $0.offset >= first && $0.offset < first + Self.rows }, id: \.offset) { i, item in
                        HStack {
                            Text(item).font(.system(size: 10.5, weight: i == sel(screen) ? .semibold : .regular)).lineLimit(1)
                            Spacer()
                            if screen < 3 || i > 0 {
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
        // like the iPod: the highlight and the list jump a row at a time, without any animation
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            selection[screen] = new
            for k in selection.keys where k > screen { selection[k] = nil }     // the next lists follow this choice
        }
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

/// Next to the switches: the iPod's menus as they will be with the current selection.
/// (Drag around the wheel to scroll, click the centre button, press MENU to go back.)
struct PreviewColumn: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let modes = PreviewMode.allCases.filter { $0.patch.map { state.patchIDs.contains($0) } ?? true }
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            if modes.count > 1 {
                Picker("Show", selection: $state.previewMode) {
                    ForEach(modes) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 230)
            }
            IPodPreview(model: state.model, patches: state.selected, patched: !state.selected.isEmpty,
                        mode: modes.contains(state.previewMode) ? state.previewMode : .menus,
                        picture: state.previewMode.patch.flatMap { state.previewPictures[$0] },
                        music: state.music)
                .help(state.previewMode == .menus
                      ? "Try it: drag around the wheel, click the centre button, press MENU to go back."
                      : "How the iPod will look after Apply.")
            if let caption {
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    /// What the picture screen shows, from the plan's result.
    private var caption: String? {
        guard let p = state.previewMode.patch, state.previewPictures[p] != nil,
              let s = state.plan?.result_states?[p.rawValue] else { return nil }
        switch (p, s) {
        case (.logo, "applied"): return "Apple logo, upside down"
        case (.logo, "custom"): return "Your own boot logo"
        case (.logo, _): return "Apple's boot logo"
        case (.dnd, "applied"): return "Your own picture"
        default: return "Apple's picture"
        }
    }
}
