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
    /// The iPod's songs (nil with the examples): the Songs menu and the songs of an album.
    var songs: [LibraryReport.Song]?

    /// Where the user is: the menus from the main menu down (MENU pops, the centre button pushes).
    @State private var stack: [Node] = [.root, .music]
    /// Direction of the last move, for the slide transition.
    @State private var forward = true
    @State private var bodyDark = false
    /// Selection per depth once the user scrolls the wheel; autoplay pauses after interaction.
    @State private var selection: [Int: Int] = [:]
    @State private var touched = Date.distantPast
    @State private var lastAngle: Double?
    @State private var turned: Double = 0

    private var depth: Int { stack.count - 1 }
    private var current: Screen { screen(stack[depth]) }
    private func sel(_ d: Int) -> Int { selection[d] ?? screen(stack[d]).sel }

    private var genre: String { patched && patches.contains(.labels) ? "Labels" : "Genres" }
    private var composer: String { patched && patches.contains(.producers) ? "Producers" : "Composers" }
    private var drillsToComposers: Bool { patched && patches.contains(.composers) }

    struct Screen { let title: String; let items: [String]; let sel: Int }
    /// Rows the screen shows at once; longer lists scroll with the selection.
    static let rows = 6

    /// A menu of the iPod, as far as the preview can show it (songs, photos and videos are not read).
    enum Node: Hashable {
        case root, music, extras, settings, playlists, allAlbums
        case labels                                           // Music ▸ Genres (Labels)
        case labelPeople(label: Int)                          // a genre's artists (composers when patched); 0 = All
        case people(composers: Bool)                          // Music ▸ Artists / Composers
        case albums(label: Int?, composers: Bool, person: Int) // a person's albums; person 0 = All
        case songs(SongFilter)                                // songs (of a genre, person and/or album)
    }

    /// Which songs a song list shows; nil = any.
    struct SongFilter: Hashable {
        var genre: String? = nil
        var person: String? = nil
        var composers = false                                 // person is the composer, else the artist
        var album: String? = nil
    }

    private func songs(_ f: SongFilter) -> [LibraryReport.Song] {
        let list = (songs ?? []).filter { s in
            (f.genre == nil || s.genre == f.genre) && (f.album == nil || s.album == f.album)
                && (f.person == nil || (f.composers ? s.composer : s.artist) == f.person)
        }
        if f.album != nil {                                   // an album plays in disc and track order
            return list.sorted { ($0.disc ?? 0, $0.track ?? 0, Self.sortKey($0.title)) < ($1.disc ?? 0, $1.track ?? 0, Self.sortKey($1.title)) }
        }
        return list.sorted { Self.sortKey($0.title).localizedStandardCompare(Self.sortKey($1.title)) == .orderedAscending }
    }
    /// The filter for row `i` of an albums list (0 = All: every song of those people).
    private func albumFilter(label l: Int?, composers c: Bool, person p: Int, row i: Int) -> SongFilter {
        let ls = labels, ps = people(label: l, composers: c)
        let genre = l == nil || l == 0 ? nil : ls[min(l! - 1, ls.count - 1)].name
        let person = p == 0 || ps.isEmpty ? nil : ps[min(p - 1, ps.count - 1)].name
        let al = albums(of: ps, p)
        return SongFilter(genre: genre, person: person, composers: c, album: i == 0 || al.isEmpty ? nil : al[min(i - 1, al.count - 1)])
    }

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
    /// Artists (or composers) of one label (row in the label list, 0 = All) or, with nil, of the whole library.
    private func people(label: Int?, composers: Bool) -> [LibraryReport.Person] {
        let ls = labels
        let gs = label == nil || label == 0 ? ls : [ls[min(label! - 1, ls.count - 1)]]
        var merged: [(name: String, albums: [String])] = []
        for g in gs {
            for p in composers ? g.composers : g.artists {
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
    /// Default person for the autoplay: the one with the most albums.
    private func defaultPerson(_ ps: [LibraryReport.Person]) -> Int {
        ps.indices.max { ps[$0].albums.count < ps[$1].albums.count } ?? 0
    }
    private func albums(of ps: [LibraryReport.Person], _ person: Int) -> [String] {
        if ps.isEmpty { return [] }
        if person == 0 { return Self.sorted(Array(Set(ps.flatMap(\.albums)))) }
        return ps[min(person - 1, ps.count - 1)].albums
    }

    private var rootItems: [String] {
        switch model {
        case .g5, .g55: return ["Music", "Photos", "Videos", "Extras", "Settings", "Shuffle Songs", "Backlight"]
        case .photo, .nano: return ["Music", "Photos", "Extras", "Settings", "Shuffle Songs", "Backlight"]
        default: return ["Music", "Extras", "Settings", "Shuffle Songs", "Backlight"]
        }
    }
    private var musicItems: [String] {
        ["Playlists", "Artists", "Albums", "Songs", genre, composer, "Audiobooks"] + (model?.isVideo == true ? ["Search"] : [])
    }
    /// Podcasts is left out, so Genres/Labels and Composers/Producers fit on the first screen.
    private static let genreRow = 4

    /// What a menu shows; `sel` is where the highlight starts (along the browse path the autoplay shows).
    private func screen(_ n: Node) -> Screen {
        switch n {
        case .root: return Screen(title: "iPod", items: rootItems, sel: 0)
        case .music: return Screen(title: "Music", items: musicItems, sel: Self.genreRow)
        case .extras:
            return Screen(title: "Extras", items: ["Clock", "Contacts", "Calendar", "Notes", "Games"] + (model?.isVideo == true ? ["Stopwatch", "Screen Lock"] : []), sel: 0)
        case .settings:
            return Screen(title: "Settings", items: ["About", "Shuffle", "Repeat", "Volume Limit", "Backlight Timer"]
                          + (model == .g4 ? [] : ["Brightness"])
                          + ["Audiobooks", "EQ", "Sound Check", "Clicker", "Date & Time", "Contacts", "Language", "Legal", "Reset All Settings"], sel: 0)
        case .playlists: return Screen(title: "Playlists", items: ["On-The-Go"], sel: 0)
        case .allAlbums:
            return Screen(title: "Albums", items: Self.sorted(Array(Set(labels.flatMap { $0.artists.flatMap(\.albums) }))), sel: 0)
        case .labels:
            return Screen(title: genre, items: ["All"] + labels.map(\.name), sel: defaultLabel + 1)
        case .labelPeople(let l):
            let ls = labels, ps = people(label: l, composers: drillsToComposers)
            return Screen(title: l == 0 ? genre : ls[min(l - 1, ls.count - 1)].name,
                          items: ["All"] + ps.map(\.name), sel: ps.isEmpty ? 0 : defaultPerson(ps) + 1)
        case .people(let c):
            let ps = people(label: nil, composers: c)
            return Screen(title: c ? composer : "Artists", items: ["All"] + ps.map(\.name), sel: 0)
        case .albums(let l, let c, let p):
            let ps = people(label: l, composers: c), al = albums(of: ps, p)
            return Screen(title: p == 0 || ps.isEmpty ? (c ? composer : "Artists") : ps[min(p - 1, ps.count - 1)].name,
                          items: ["All"] + al, sel: al.isEmpty ? 0 : 1)
        case .songs(let f):
            return Screen(title: f.album ?? f.person ?? f.genre ?? "Songs", items: songs(f).map(\.title), sel: 0)
        }
    }

    /// The menu the centre button opens from row `i` of `n`, or nil (songs, photos etc. aren't shown).
    private func child(_ n: Node, _ i: Int) -> Node? {
        switch n {
        case .root:
            switch rootItems[i] { case "Music": return .music; case "Extras": return .extras; case "Settings": return .settings; default: return nil }
        case .music:
            switch i {
            case 0: return .playlists
            case 1: return .people(composers: false)
            case 2: return .allAlbums
            case 3: return songs?.isEmpty == false ? .songs(SongFilter()) : nil
            case Self.genreRow: return .labels
            case Self.genreRow + 1: return .people(composers: true)
            default: return nil
            }
        case .labels: return .labelPeople(label: i)
        case .labelPeople(let l):
            return people(label: l, composers: drillsToComposers).isEmpty ? nil : .albums(label: l, composers: drillsToComposers, person: i)
        case .people(let c):
            return people(label: nil, composers: c).isEmpty ? nil : .albums(label: nil, composers: c, person: i)
        case .albums(let l, let c, let p):
            let f = albumFilter(label: l, composers: c, person: p, row: i)
            return songs(f).isEmpty ? nil : .songs(f)
        case .allAlbums:
            let al = screen(.allAlbums).items
            guard al.indices.contains(i) else { return nil }
            let f = SongFilter(album: al[i])
            return songs(f).isEmpty ? nil : .songs(f)
        default: return nil
        }
    }

    /// The browse path the autoplay walks: main menu ▸ Music ▸ Genres/Labels ▸ a label ▸ a person.
    private var demo: [Node] {
        let l = defaultLabel + 1, ps = people(label: l, composers: drillsToComposers)
        return [.root, .music, .labels, .labelPeople(label: l)]
            + (ps.isEmpty ? [] : [.albums(label: l, composers: drillsToComposers, person: defaultPerson(ps) + 1)])
    }

    /// Name of a menu in the breadcrumb.
    private func crumb(_ n: Node) -> String {
        switch n {
        case .root: return "iPod"
        case .music: return "Music"
        case .extras: return "Extras"
        case .settings: return "Settings"
        case .playlists: return "Playlists"
        case .labels: return genre
        case .labelPeople: return drillsToComposers ? composer : "Artists"
        case .people(let c): return c ? composer : "Artists"
        case .albums, .allAlbums: return "Albums"
        case .songs: return "Songs"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            device
                .frame(width: 210, height: 340)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            // breadcrumb of the browse path
            if mode == .menus { breadcrumb }
        }
        // Switching a change keeps the place, so the difference shows where you are.
        .onChange(of: drillsToComposers) {
            touched = Date()                                     // hold the autoplay a moment
            withAnimation(.easeInOut(duration: 0.2)) {
                // a label's artists <-> composers: that person may not be in the other list
                if let i = stack.firstIndex(where: { if case .labelPeople = $0 { return true }; return false }) {
                    stack = Array(stack.prefix(i + 1))
                    for k in selection.keys where k >= i { selection[k] = nil }
                }
            }
        }
        .onChange(of: patches) { touched = Date() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.9))
                guard mode == .menus, Date().timeIntervalSince(touched) > 8 else { continue }  // the user is driving
                // walk the browse path one menu deeper each step, then start again at the main menu
                let path = demo
                let next = stack.count < path.count && Array(path.prefix(stack.count)) == stack ? stack.count + 1 : 1
                forward = next > 1
                withAnimation(.snappy(duration: 0.35)) { stack = Array(path.prefix(next)); selection = [:] }
            }
        }
    }

    private var breadcrumb: some View {
            HStack(spacing: 4) {
                ForEach(Array(stack.enumerated()), id: \.offset) { i, n in
                    let p = crumb(n)
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(p)
                        .fontWeight(highlight(p) ? .bold : .regular)
                        .foregroundStyle(highlight(p) ? Theme.phosphor : i == depth ? Color.primary : .secondary)
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

    private var dark: Bool { model?.isVideo == true && bodyDark }

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
        .onTapGesture { if model?.isVideo == true { withAnimation { bodyDark.toggle() } } }
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
        let s = current, node = stack[depth]
        return GeometryReader { g in
        // the rows share the height under the title bar, so the last one ends at the bottom of the screen
        // (minus the 2-point frame drawn over the screen's edge)
        let rowHeight = (g.size.height - 17 - (color ? 0.5 : 1) - 2) / CGFloat(Self.rows)
        ZStack(alignment: .top) {
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
                    let first = max(0, min(sel(depth) - (Self.rows - 1), s.items.count - Self.rows))
                    ForEach(Array(s.items.enumerated()).filter { $0.offset >= first && $0.offset < first + Self.rows }, id: \.offset) { i, item in
                        HStack {
                            Text(item).font(.system(size: 10.5, weight: i == sel(depth) ? .semibold : .regular)).lineLimit(1)
                            Spacer()
                            if child(node, i) != nil {
                                Image(systemName: "chevron.right").font(.system(size: 7, weight: .heavy))
                            }
                        }
                        .padding(.horizontal, 5)
                        .frame(height: rowHeight)
                        .foregroundStyle(i == sel(depth) ? .white : .black)
                        .background {
                            if i == sel(depth) {
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
                .id(stack)
                .transition(.push(from: forward ? .trailing : .leading))
            }
        }
        }
    }

    private func click() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func scroll(_ d: Int) {
        let n = current.items.count
        let new = max(0, min(n - 1, sel(depth) + d))
        guard new != sel(depth) else { return }
        touched = Date()
        // like the iPod: the highlight and the list jump a row at a time, without any animation
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { selection[depth] = new }
        click()
    }

    /// Centre button: open the selected item's menu.
    private func open() {
        touched = Date()
        guard let next = child(stack[depth], sel(depth)) else { return }
        forward = true
        selection[depth] = sel(depth)                          // keep the place to come back to
        for k in selection.keys where k > depth { selection[k] = nil }
        selection[depth + 1] = 0                               // like the iPod: a menu opens at its first item
        withAnimation(.snappy(duration: 0.3)) { stack.append(next) }
        click()
    }

    /// MENU: back to the menu above (the main menu stays).
    private func back() {
        touched = Date()
        guard depth > 0 else { return }
        forward = false
        selection[depth] = nil
        withAnimation(.snappy(duration: 0.3)) { _ = stack.removeLast() }
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
                .onTapGesture { open() }
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            Group {
                Text("MENU").font(.system(size: 9.5, weight: .bold))
                    .padding(8).contentShape(Rectangle())
                    .onTapGesture { back() }
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
                        music: state.music, songs: state.songs)
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
        case (.logo, "custom"): return state.mirrored.contains(.logo) ? "Apple logo, mirrored" : "Your own boot logo"
        case (.logo, _): return "Apple's boot logo"
        case (.dnd, "applied"): return "Your own picture"
        default: return "Apple's picture"
        }
    }
}
