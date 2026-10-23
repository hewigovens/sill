import AppKit
import AVFoundation
import Combine
import StreamProtocol

/// The other Mac's windows as this Mac's windows. Each window opened from the status item (and the
/// Desktop) is a window here, sized 1:1 in points to the window there, with no frame of its own: the
/// title bar is transparent and the picture fills it, so the other window's own title bar and
/// buttons sit under this window's, which close and minimize it here.
///
/// Every window open here is live. The key one is the host's main stream (kind 6, full rate, the one
/// input goes to); the stream view (`StreamInputView`, the client's display) moves to it. Each other
/// window of the host's is a side stream (kinds 29–31) at a lower rate, drawn by the window's own
/// layer (`SideView`); a host before side streams leaves them on its latest thumbnail. Focusing a
/// window makes it the main stream; its side picture stays until the main stream's first keyframe.
/// Main thread.
/// DEBUG: what the window manager does, on stderr ("windows: …").
func windowLog(_ line: @autoclosure () -> String) {
    #if DEBUG
    FileHandle.standardError.write(Data("windows: \(line())\n".utf8))
    #endif
}

final class StreamWindows: NSObject, NSWindowDelegate {
    private let client: StreamClient
    private(set) lazy var input: StreamInputView = {
        let view = StreamInputView(client: client)
        view.live = live
        return view
    }()
    /// A drag of files followed live on the other Mac (kind 38).
    private lazy var live = LiveDrop(client: client)
    private var open: [StreamSource: StreamWindow] = [:]
    /// The window whose stream the picture shows, once the host has switched to it.
    private var showing: StreamSource?
    private var subscriptions = Set<AnyCancellable>()
    /// Where the main stream is drawn: the focused window's own layer, switched when the new
    /// stream's parameter sets arrive (MainRouter), so no window ever shows another's picture.
    private let router = MainRouter()
    /// The last source this Mac asked the host for (a focus): the host drops a pick that comes while
    /// it is still switching, so one its list does not name is asked for again.
    private var requested: StreamSource?
    /// A Dock icon per remote app with a window open here.
    let dock = DockProxies()
    /// The focused window's controls (close, minimize, full screen, its title), above it.
    private let pill = WindowPill()
    /// Every window the host has listed this session: a window new to it opens here by itself when
    /// its app has a window open here (a new document, a dialog).
    private var known: Set<UInt32>?
    /// Each window's app, as the host last listed it (kept after the window leaves the list).
    private var appOf: [UInt32: String] = [:]

    init(client: StreamClient) {
        self.client = client
        super.init()
        client.$active.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.activeChanged(self.local(self.client.active)) }
        }.store(in: &subscriptions)
        // Another display picked while the Desktop streams: the stream goes to that display's window.
        client.$desktopDisplay.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.client.active == .desktop else { return }
                self.activeChanged(self.local(.desktop))
            }
        }.store(in: &subscriptions)
        client.$windows.sink { [weak self] list in
            DispatchQueue.main.async { self?.windowsChanged(list) }
        }.store(in: &subscriptions)
        // An app's icon can come after its Dock icon started: it is badged and shown then.
        client.$icons.sink { [weak self] _ in DispatchQueue.main.async { self?.syncDock() } }.store(in: &subscriptions)
        client.$thumbnails.sink { [weak self] thumbs in
            DispatchQueue.main.async { self?.thumbnailsChanged(thumbs) }
        }.store(in: &subscriptions)
        client.$hostSideStreams.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.requestSideStreams() }
        }.store(in: &subscriptions)
        // The other Mac's Dock badges on this Mac's Dock icons of its apps.
        client.$hostBadges.removeDuplicates().sink { [weak self] badges in
            DispatchQueue.main.async { windowLog("dock: badges on the other Mac: \(badges)"); self?.syncDock() }
        }.store(in: &subscriptions)
        // Its apps bouncing their Dock icons there: their Dock icons here bounce until they stop.
        client.$hostAttention.removeDuplicates().sink { [weak self] apps in
            DispatchQueue.main.async { windowLog("dock: asking for attention on the other Mac: \(apps.sorted())"); self?.syncDock() }
        }.store(in: &subscriptions)
        client.$hostAudio.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.requestSideStreams() }
        }.store(in: &subscriptions)
        let feeds = sideFeeds, route = router
        // Side streams through the router: never into the window the main stream draws, and a side
        // frame only after its own parameter sets (MainRouter).
        client.onSideParameterSets = { id, ps in
            if let feed = feeds.get(id) { route.sideParameterSets(ps, into: feed) }
        }
        client.onSideFrame = { id, data, isKey in
            if let feed = feeds.get(id) { route.sideFrame(data, isKeyframe: isKey, into: feed) }
        }
        dock.onFocus = { [weak self] app, window in self?.focus(app: app, window: window) }
        pill.onFullSpeed = { [weak self] window in self?.toggleFullSpeed(window) }
        dock.onLaunch = { [weak self] app in self?.launchFromDock(app) }
        dock.askMenu = { [weak self] app in
            guard let self, self.client.hostDockMenu, self.client.connected else { return }
            self.client.send(.dockMenu, payload: Wire.encode(DockMenu(app: app, token: UInt32.random(in: 1...UInt32.max))))
        }
        dock.pressMenu = { [weak self] app, id, title in
            guard let self, self.client.hostDockMenu, self.client.connected else { return }
            windowLog("dock: \(app) › \(title) pressed on the other Mac")
            self.client.send(.dockMenu, payload: Wire.encode(DockMenu(app: app, token: UInt32.random(in: 1...UInt32.max), press: id, title: title)))
        }
        // The pill's refresh: the other Mac makes its hidden displays again (a picture black or wrong).
        pill.onRefresh = { [weak self] in
            guard let self, self.client.hostRebuildDesk, self.client.connected else { return }
            windowLog("refresh: asking the other Mac to make its hidden displays again")
            self.client.send(.rebuildDesk, payload: Data())
        }
        client.$hostRebuildDesk.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePill() }
        }.store(in: &subscriptions)
        // The other Mac's menus in the menu bar: this app has none of its own (an accessory app, no Dock
        // icon), so the app's Dock icon holds them and takes the menu bar while one of its windows is
        // in front (DockProxies.takeMenuBar); it asks for each menu as it opens and passes a choice back.
        dock.onMenuOpen = { [weak self] app, id, top, title, token in self?.menuOpened(app, id: id, top: top, title: title, token: token) }
        dock.onMenuPress = { [weak self] app, id, title in
            guard let self, app == self.streamedApp, let row = self.menuRows[app]?[id], row.title == title else { return }
            windowLog("menus: \(title) chosen in the menu bar")
            self.client.pressMenuItem(row)
        }
        client.$menus.sink { [weak self] _ in DispatchQueue.main.async { self?.menusChanged() } }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleMenuBar()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cameForward = !(self.lastOtherFront?.hasPrefix(DockProxies.iconIDPrefix) ?? false)
            self.scheduleMenuBar()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastOtherFront = app.bundleIdentifier
            // A Dock icon in front (its menu bar open) is this app in front; another app is not.
            self?.updatePill()
            self?.appActiveChanged(ownChange: false)
        }
        // The person at the other Mac took these windows back: they close here (and may be opened again).
        client.onTakenBack = { [weak self] ids in
            guard let self else { return }
            windowLog("taken back by the other Mac: \(ids)")
            for id in ids { self.open[.window(id)]?.close() }
        }
        client.onDockMenu = { [weak self] menu in
            guard let items = menu.items else { return }
            windowLog("dock: \(menu.app)'s menu on the other Mac: \(items.filter { $0.separator != true }.map(\.title))")
            self?.dock.setMenu(menu.app, items)
        }
        dock.onClose = { [weak self] app in
            guard let self else { return }
            for (source, window) in self.open {
                if case .window(let id) = source, self.appOf[id] == app { window.close() }
            }
        }
        client.onDragOffer = { [weak self] offer in self?.input.dragOffer = offer.files.isEmpty ? nil : offer }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updatePill()
                self?.appActiveChanged()
                // On activation the key window can come a moment later (a click on a window that was
                // key while the app was in the background): look again then.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.updatePill() }
            }
        }
        _ = input   // makes the display view, which takes the client's frame hooks
        // The display view decodes too, for the picture's geometry (input), but never shows: each
        // window's own layer is its picture, the main stream's while it is focused.
        input.display.isHidden = true
        input.viewportAllowed = { [weak self] in
            guard let self, let window = self.input.window as? StreamWindow else { return false }
            return window.source == self.local(self.client.active) && window.source == self.showing
        }
        input.holding = { [weak self] in
            guard let self, let wanted = self.requested else { return false }
            return self.local(self.client.active) != wanted
        }
        let router = self.router
        // The Desktop as the window of the display it shows (Self.local), so two displays are two streams.
        client.onWindowListActive = { active, display in
            router.listed(active: active == .desktop && display != nil ? .window(DesktopWindow.id(display: display!)) : active)
        }
        let shownPS = client.onParameterSets
        client.onParameterSets = { ps in shownPS?(ps); router.parameterSets(ps) }
        let shownFrame = client.onFrame
        client.onFrame = { data, isKey in shownFrame?(data, isKey); router.frame(data, isKeyframe: isKey) }
    }

    var openSources: Set<StreamSource> { Set(open.keys) }

    // MARK: Windows kept across sessions

    /// A window open here, as remembered for the next session with this Mac: its ID (stable while
    /// its app runs), and its app and title to find it again after the app relaunched.
    private struct Kept: Codable { let id: UInt32; let app: String; let title: String }
    private var keptKey: String { "SillClient.openWindows." + client.macName }
    /// Off while windows close for the session's end, so the list survives it.
    private var keeping = true
    /// The list has been looked at for this session.
    private var restored = false

    private func keep() {
        guard keeping, client.connected, !client.macName.isEmpty else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillResizeTest") { return }   // never the real session's list
        #endif
        let ordered = NSApp.orderedWindows.compactMap { $0 as? StreamWindow }.map(\.source).filter { open[$0] != nil }.reversed()
        let kept = ordered.compactMap { source -> Kept? in
            guard case .window(let id) = source, let w = client.windows.first(where: { $0.id == id }) else { return nil }
            return Kept(id: id, app: w.bundleID, title: w.title)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: keptKey)
    }

    /// The windows open in the last session with this Mac, opened again (back to front, the last one
    /// key), once its first list has come.
    private func restore() {
        guard !restored, client.connected, !client.windows.isEmpty else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillResizeTest") { restored = true; return }   // the test's own window only
        #endif
        restored = true
        windowLog("restore: key \(keptKey), saved \(UserDefaults.standard.data(forKey: keptKey)?.count ?? 0) bytes")
        guard let data = UserDefaults.standard.data(forKey: keptKey),
              let kept = try? JSONDecoder().decode([Kept].self, from: data), !kept.isEmpty else { return }
        var used = Set<UInt32>()
        let found = kept.compactMap { k -> UInt32? in
            let w = client.windows.first { $0.id == k.id && !used.contains($0.id) }
                ?? client.windows.first { $0.bundleID == k.app && $0.title == k.title && !used.contains($0.id) }
            guard let w else { return nil }
            used.insert(w.id)
            return w.id
        }
        for (i, id) in found.enumerated() { open(.window(id), focus: i == found.count - 1) }
    }

    /// Each window's side stream decoder, by the host's window ID, for the network queue.
    private let sideFeeds = FeedBox()

    /// Every window open here but the main stream's, as side streams (a host that streams fewer
    /// takes the first ones: the most recently used first).
    func requestSideStreams() {
        guard client.connected else { return }
        // Every window open here, the focused one too: the host streams it as the main stream, not
        // as a side one, and keeps them all on Sill's desk, also between two picks.
        // Only windows still open: a closing one is still among AppKit's while it closes, and asked
        // for then, the host kept it on its desk, captured, the sharing indicator on.
        // A window minimised into its app's Dock icon is put away, so not among AppKit's ordered ones:
        // still asked for, last, so the host keeps it on its desk.
        let windows = NSApp.orderedWindows.compactMap { $0 as? StreamWindow }.filter { open[$0.source] === $0 }
            + open.values.filter { $0.parked }
        let ids = windows.compactMap { Self.sideID($0.source) }
        // Those no one can see here (minimised, or wholly covered or off screen): kept on the host's
        // desk, not captured or sent, until they can be seen again. Never the one streaming.
        let paused = windows.filter { window in
            window.source != showing && (window.parked || window.isMiniaturized || !window.occlusionState.contains(.visible))
        }.compactMap { Self.sideID($0.source) }
        // Every window with what belongs to it: its menus, popovers, sheets and the system's panels.
        client.requestSideStreams(ids, wholeApp: true, screen: Self.largestScreen,
                                  audio: client.hostAudio && AudioPlayer.enabled ? true : nil, audioCodec: AudioPlayer.codec,
                                  fullRate: fullSpeed.filter { ids.contains($0) }, paused: paused, background: inBackground)
    }

    /// Since when this app has been out of front: after `backgroundDelay` the main stream is a
    /// background window too (`SideStreamRequest.background`), so a glance at another app and back
    /// costs no restart.
    private var inactiveSince: Date?
    private static let backgroundDelay: TimeInterval = 3
    private var inBackground: Bool { inactiveSince.map { Date().timeIntervalSince($0) >= Self.backgroundDelay - 0.05 } ?? false }

    /// This app is in front, or one of its Dock icons is (it holds the menu bar, and a menu may be open).
    private var inFront: Bool {
        NSApp.isActive || NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix(DockProxies.iconIDPrefix) == true
    }

    /// `ownChange`: this app became active or resigned (another app coming forward changes nothing
    /// to send unless it ends a spell out of front).
    private func appActiveChanged(ownChange: Bool = true) {
        if inFront {
            let wasOut = inactiveSince != nil
            inactiveSince = nil
            if ownChange || wasOut { requestSideStreams() }
        } else if inactiveSince == nil {
            let since = Date()
            inactiveSince = since
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundDelay) { [weak self] in
                guard let self, self.inactiveSince == since else { return }
                // Its Dock icon in front since (its menus open): still in front.
                if self.inFront { self.inactiveSince = nil; return }
                self.requestSideStreams()
            }
        }
    }

    // MARK: The menu bar, held by the app's Dock icon

    /// The app the main stream shows: the other Mac sends its menus.
    private var streamedApp: String? {
        if case .window(let id) = local(client.active) { return appOf[id] }
        return nil
    }
    /// The rows the Dock icons were sent, by app and the other Mac's id: a choice or a submenu's
    /// opening names one.
    private var menuRows: [String: [String: MacMenuState.Row]] = [:]

    /// The streamed app's top-level menus to its Dock icon, when they changed (or the icon is a new
    /// process); its shape then, or nil when nothing streams.
    @discardableResult
    private func sendMenuBar() -> (app: String, shape: String)? {
        guard let app = streamedApp else { return nil }
        let state = client.menus
        let top = state.menus.compactMap { row in row.id.map { (id: $0, title: row.title, enabled: row.enabled && !state.stale) } }
        let note = top.isEmpty ? state.note : nil
        let shape = "\(dock.iconPID(app) ?? 0)#" + top.map { "\($0.id)|\($0.title)|\($0.enabled)" }.joined(separator: ",") + "#" + (note ?? "")
        if sentShape[app] != shape {
            sentShape[app] = shape
            dock.setMenuBar(app, top: top, note: note)
        }
        return (app, shape)
    }

    /// The other Mac's menus changed: shown by the icon taking the bar again when its window is in front
    /// (an owner that is not active keeps showing what it had).
    private func menusChanged() {
        guard let sent = sendMenuBar(), sent.app == keyApp, shownShape[sent.app] != sent.shape else { return }
        scheduleMenuBar()
    }
    /// Each app's menus as last sent to its Dock icon, and as it last took the bar with.
    private var sentShape: [String: String] = [:]
    private var shownShape: [String: String] = [:]

    /// The app of the window in front here, if it has a Dock icon.
    private var keyApp: String? {
        guard NSApp.isActive, let key = NSApp.keyWindow as? StreamWindow, case .window(let id) = key.source,
              let app = appOf[id], dock.hasIcon(app) else { return nil }
        return app
    }

    /// The menu bar's hand-over, once this app is active with its key window (they come in either order)
    /// and no button is down (taken mid-click, the Dock icon's moment in front lost the click).
    private func scheduleMenuBar(after delay: Double = 0.15) {
        menuBarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleMenuBar(after: 0.1); return }
            self.menuBarToFront()
        }
        menuBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var menuBarWork: DispatchWorkItem?

    /// The front window's app's Dock icon takes the menu bar: always when this app came forward or the
    /// front app changed (after ⌘Tab or the Dock, macOS names the icon the owner while the bar still
    /// shows the app before), and when its menus changed since it last took it; never twice within a
    /// second (its own hand-back would repeat it).
    private func menuBarToFront() {
        let forward = cameForward
        cameForward = false
        guard let app = keyApp else { return }
        // Until the other Mac streams this window's app, the menus it sent are another app's: they say
        // nothing of this one's (compared, every click forced a hand-over while the stream switched).
        let sent = sendMenuBar()
        let shape = sent?.app == app ? sent?.shape : shownShape[app]
        let recent = lastMenuBar.map { $0.app == app && Date().timeIntervalSince($0.at) < 1 } ?? false
        let force = !recent && (forward || lastMenuBar?.app != app || shownShape[app] != shape)
        dock.takeMenuBar(app, force: force)
        if force || lastMenuBar?.app != app { lastMenuBar = (app, Date()) }
        shownShape[app] = shape
    }
    /// This app came forward from another (not from one of its own Dock icons, whose menus were in use).
    private var cameForward = false
    /// The app whose Dock icon last took the menu bar, and when.
    private var lastMenuBar: (app: String, at: Date)?
    /// The last app other than this one in front, to tell a return from a Dock icon's menus.
    private var lastOtherFront: String?

    private func menuOpened(_ app: String, id: String, top: Bool, title: String, token: String) {
        let answer: (MacMenuState.Content) -> Void = { [weak self] content in self?.answerMenu(app, token: token, content) }
        guard app == streamedApp else {
            dock.setMenuContent(app, token: token, content: ["message": "Click one of this app’s windows for its menus."])
            return
        }
        if top {
            guard let version = client.menus.version else { return answer(.message("The menus are on their way.")) }
            client.fetchTopMenu(id: id, title: title, builtVersion: version, completion: answer)
        } else {
            guard let row = menuRows[app]?[id] else { return answer(.message("The menus changed; open it again.")) }
            client.fetchMenu(row, completion: answer)
        }
    }

    private func answerMenu(_ app: String, token: String, _ content: MacMenuState.Content) {
        switch content {
        case .message(let text):
            dock.setMenuContent(app, token: token, content: ["message": text])
        case .sections(let sections, let more):
            var rows = menuRows[app] ?? [:]
            let encoded = sections.map { section in
                section.map { row -> [String: String] in
                    if let id = row.id { rows[id] = row }
                    let kind = row.kind == .submenu ? "submenu" : row.kind == .note ? "note" : "item"
                    let mark = row.mark == .on ? "on" : row.mark == .mixed ? "mixed" : "off"
                    return ["kind": kind, "id": row.id ?? "", "title": row.title, "key": row.key ?? "",
                            "enabled": row.enabled ? "1" : "0", "mark": mark]
                }
            }
            menuRows[app] = rows
            dock.setMenuContent(app, token: token, content: ["sections": encoded, "more": more])
        }
    }

    /// The windows marked full speed in their pill (the bolt), oldest first, at most
    /// `SideStreamRequest.maxFullRate`: streamed at the main stream's rate when not in front, where the
    /// others get 15 fps. For this session: a window's ID is the other Mac's, and lives as long as it.
    private var fullSpeed: [UInt32] = []

    /// The pill's bolt: full speed on or off for the focused window. A mark beyond the limit takes the
    /// oldest's; the pill says which went back to 15 fps.
    private func toggleFullSpeed(_ window: StreamWindow) {
        guard let id = Self.sideID(window.source) else { return }
        if let i = fullSpeed.firstIndex(of: id) {
            fullSpeed.remove(at: i)
        } else {
            fullSpeed.append(id)
            if fullSpeed.count > SideStreamRequest.maxFullRate {
                let dropped = fullSpeed.removeFirst()
                let name = open[.window(dropped)].map { $0.title } ?? "another window"
                pill.note("\(name) back to 15 fps in the background")
            }
        }
        windowLog("full speed: \(fullSpeed)")
        updatePill()
        requestSideStreams()
    }

    /// A window's ID as side streams name it (a Desktop window's display tagged, DesktopWindow).
    private static func sideID(_ source: StreamSource) -> UInt32? {
        guard case .window(let id) = source else { return nil }
        return id
    }

    /// This Mac's largest display, in points: the room the host keeps for each window (Sill's desk).
    static var largestScreen: CGSize? {
        NSScreen.screens.map(\.frame.size).max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Shows the window for `source`, making it if there is none, and gives it the keyboard, which
    /// asks the host for its stream.
    func open(_ source: StreamSource, focus: Bool = true) {
        windowLog("open \(source) focus \(focus) (already open: \(open[source] != nil))")
        guard source != .none else { return }
        if let window = open[source] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            unpark(window)
            if focus { window.makeKeyAndOrderFront(nil); NSApp.activate() } else { window.orderFront(nil) }
            return
        }
        let window = StreamWindow(source: source, size: initialSize(source))
        window.delegate = self
        window.onMinimize = { [weak self] window in self?.park(window) ?? false }
        if case .window(let id) = source {
            window.container.over = { [weak self] info, at in self?.dragOver(info, at: at, window: id) ?? [] }
            window.container.exited = { [weak self] info in self?.live.exited(info) }
            window.container.onDrop = { [weak self] info, at in self?.dropped(info, at: at, window: id) ?? false }
            window.container.onBackgroundInput = { [weak self] event in self?.client.sendWindowInput(id, event) }
            window.container.onBackgroundPress = { [weak self, weak window] event in
                guard let self, let window else { return }
                self.heldPress = (window.source, event.locationInWindow, Date())
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
        window.title = title(source)
        window.placeholder.image = thumbnail(source)
        if case .window(let id) = source {
            sideFeeds.set(id, window.side.feed)
            appOf[id] = client.windows.first { $0.id == id }?.bundleID ?? appOf[id]
        }
        open[source] = window
        router.register(source, window.side.feed)   // the main stream goes here whenever the host streams this
        defer { syncDock(); keep() }
        window.center()
        if let key = NSApp.keyWindow as? StreamWindow, key !== window {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
        }
        if focus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
            requestSideStreams()
        }
    }

    // MARK: Drops on a window shown beside the streamed one

    /// Followed live on a Mac that takes that (LiveDrop), else only accepted for a drop where let go.
    private func dragOver(_ info: NSDraggingInfo, at: CGPoint, window: UInt32) -> NSDragOperation {
        if live.enabled { return live.over(info, window: window, at: at) }
        return acceptsDrop(info) ? .copy : []
    }

    private func acceptsDrop(_ info: NSDraggingInfo) -> Bool {
        guard client.hostFileDrop, client.connected else { return false }
        let ok = info.draggingSource is StreamInputView ? !input.outgoing.isEmpty : !droppedFiles(info).isEmpty
        windowLog("drop: over a window, source \(String(describing: info.draggingSource.map { type(of: $0) })), own files \(input.outgoing.count), types \(info.draggingPasteboard.types?.map(\.rawValue).prefix(4) ?? []) → \(ok)")
        return ok
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        LiveDrop.files(info)
    }

    /// Files from this Mac go across and are dropped there; the other Mac's own files, dragged out of
    /// one of its windows, are dropped from where they are, nothing copied either way.
    private func dropped(_ info: NSDraggingInfo, at: CGPoint, window: UInt32) -> Bool {
        windowLog("drop: let go on window \(window) at \(at)")
        if live.enabled { return live.drop(info, window: window, at: at) }
        guard client.hostFileDrop else { return false }
        if info.draggingSource is StreamInputView {
            let own = input.outgoing
            guard let offer = own.first?.offer else { return false }
            input.outgoing = []
            client.send(.fileDrop, payload: Wire.encode(FileDrop(files: own.map { UInt32($0.index) }, x: Double(at.x), y: Double(at.y),
                                                                  offer: offer, window: window)))
            windowLog("drop: \(own.count) of the other Mac's own files moved onto window \(window), nothing copied")
            return true
        }
        let urls = droppedFiles(info)
        guard !urls.isEmpty else { return false }
        StreamInputView.send(urls, at: at, client: client, window: window)
        return true
    }

    /// The Dock icons follow the windows open here, by app.
    private func syncDock() {
        var apps: [String: DockProxies.AppWindows] = [:]
        var byApp: [String: [DockProxies.Window]] = [:]
        // Each app's front window (the Dock's ✓): the first of its windows here in this Mac's order.
        var front: [String: UInt32] = [:]
        for case let window as StreamWindow in NSApp.orderedWindows where !window.isMiniaturized && window.isVisible {
            if case .window(let id) = window.source, let app = appOf[id], front[app] == nil { front[app] = id }
        }
        for (source, window) in open {
            guard case .window(let id) = source, let app = appOf[id] else { continue }
            let w = client.windows.first { $0.id == id }
            let state: DockProxies.Window.State = window.isMiniaturized || window.parked ? .minimized : (front[app] == id ? .front : .other)
            byApp[app, default: []].append(DockProxies.Window(id: id, title: w.map { $0.title.isEmpty ? $0.appName : $0.title } ?? title(source),
                                                              state: state, parked: window.parkedPicture.map { (window.frame, $0) }))
        }
        for (app, windows) in byApp {
            // The window's app name, else the installed app's (a window of another Space can come
            // with none), never the bundle ID if either is known.
            let name = [client.windows.first { $0.bundleID == app && !$0.appName.isEmpty }?.appName,
                        client.apps.first { $0.bundleID == app }?.name].compactMap { $0 }.first ?? app
            apps[app] = DockProxies.AppWindows(name: name, icon: client.icons[app], windows: windows.sorted { $0.title < $1.title },
                                               badge: client.hostBadges[app], attention: client.hostAttention.contains(app))
        }
        dock.sync(apps)
    }

    /// Minimised into its app's Dock icon rather than Sill Viewer's: macOS minimises a window only into
    /// its own app, and this window is Sill Viewer's, so the app's Dock icon minimises a stand-in with
    /// the window's last picture (DockProxies, `parked`) while this one is put away; restoring the
    /// stand-in, or the window picked anywhere here, brings this one back. False (macOS minimises it
    /// itself) for a Desktop window, or an app with no Dock icon here.
    private func park(_ window: StreamWindow) -> Bool {
        guard case .window(let id) = window.source, let app = appOf[id], dock.hasIcon(app) else { return false }
        guard let image = Self.picture(of: window), let path = DockProxies.writePicture(image, app: app, window: id) else { return false }
        windowLog("park \(window.source) in \(app)'s Dock icon")
        window.parkedPicture = path
        window.orderOut(nil)
        if let next = NSApp.orderedWindows.compactMap({ $0 as? StreamWindow }).first(where: { $0.isVisible && !$0.isMiniaturized }) {
            next.makeKeyAndOrderFront(nil)
        }
        updatePill()
        syncDock()
        requestSideStreams()
        return true
    }

    /// Back from its app's Dock icon: shown again (the caller makes it key), and the stand-in goes.
    private func unpark(_ window: StreamWindow) {
        guard window.parked else { return }
        windowLog("unpark \(window.source)")
        window.forgetPicture()
        window.orderFront(nil)
        syncDock()
        requestSideStreams()
    }

    /// The window as it is on screen: its own, which needs no Screen Recording permission.
    /// CGWindowListCreateImage is gone from the SDK's Swift interface but not from macOS; nil if it ever is.
    private static func picture(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    /// A hide of the pill waiting out `pillHideDelay` (`updatePill`).
    private var pillHide: DispatchWorkItem?
    /// How long the pill stays up with neither this app nor its Dock icon in front, or no key window.
    private static let pillHideDelay: TimeInterval = 0.3

    private func updatePill() {
        guard inFront, let key = NSApp.keyWindow as? StreamWindow else {
            // Not at once: a click on a window passes the front between this app and the app's Dock
            // icon (it takes the menu bar, then hands it back), and for a moment neither reads as in
            // front, nor is a window key; the pill hid and showed a few times on each click. It hides
            // once that has lasted `pillHideDelay`.
            guard pillHide == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pillHide = nil
                if self.inFront, NSApp.keyWindow is StreamWindow { self.updatePill() } else { self.pill.show(over: nil, title: "", image: nil) }
            }
            pillHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillHideDelay, execute: work)
            return
        }
        pillHide?.cancel()
        pillHide = nil
        var image: NSImage?
        // The app's icon with Sill Viewer's in its corner, as its Dock icon has it: the other Mac's
        // window, not this Mac's; a Desktop window has Sill Viewer's own.
        if case .window(let id) = key.source, let app = appOf[id], let icon = client.icons[app] {
            image = badgedIcons[app] ?? { let b = DockProxies.badged(icon); badgedIcons[app] = b; return b }()
        } else if display(of: key.source) != nil || key.source == .desktop {
            image = NSApp.applicationIconImage
        }
        pill.show(over: key, title: title(key.source), image: image,
                  fullSpeed: client.hostFullRate ? Self.sideID(key.source).map { fullSpeed.contains($0) } : nil,
                  refresh: client.hostRebuildDesk)
    }

    /// From a Dock icon: one window, or every window of the app (the most recent one key).
    private func focus(app: String, window: UInt32?) {
        if let window { open(.window(window)); return }
        // A window minimised into the app's Dock icon stays there, as on a Mac: the icon restores it.
        let mine = NSApp.orderedWindows.compactMap { $0 as? StreamWindow }.filter {
            guard case .window(let id) = $0.source else { return false }
            return appOf[id] == app
        }
        for w in mine.reversed() { if w.isMiniaturized { w.deminiaturize(nil) }; w.orderFront(nil) }
        mine.first?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }


    /// Apps whose Dock icon, kept in the Dock, was clicked before the other Mac was connected.
    private var dockLaunches: Set<String> = []
    /// Each app's icon badged as the other Mac's, for the pill.
    private var badgedIcons: [String: NSImage] = [:]
    private var lastDockLaunch: [String: Date] = [:]

    /// A kept Dock icon clicked with none of its app's windows open here: its windows on the other
    /// Mac open here, or, with none there, the app is launched there (its first window then streams
    /// here, as an app opened from the status item does).
    private func launchFromDock(_ app: String) {
        guard client.connected, known != nil else { dockLaunches.insert(app); return }
        dockLaunches.remove(app)
        // The Dock icon asks as it starts and as it becomes active: one answer.
        if let last = lastDockLaunch[app], Date().timeIntervalSince(last) < 3 { return }
        lastDockLaunch[app] = Date()
        let theirs = client.windows.filter { $0.bundleID == app && !$0.title.isEmpty && $0.width >= 80 && $0.height >= 150 }
        windowLog("dock: \(app) asked for from the Dock: \(theirs.isEmpty ? "launching it" : "\(theirs.count) window(s)")")
        if theirs.isEmpty { client.launch(bundleID: app); return }
        for w in theirs.dropFirst().reversed() { open(.window(w.id), focus: false) }
        open(.window(theirs[0].id), focus: true)
    }

    func closeAll() {
        pill.show(over: nil, title: "", image: nil)
        keeping = false
        defer { keeping = true; restored = false }
        for window in open.values { window.delegate = nil; window.forgetPicture(); window.close() }
        open.removeAll()
        fullSpeed.removeAll()
        menuRows.removeAll(); sentShape.removeAll(); shownShape.removeAll(); lastMenuBar = nil; cameForward = false
        known = nil
        sideFeeds.removeAll()
        client.requestSideStreams([], wholeApp: true, screen: Self.largestScreen)
        dock.quitAll()
        router.reset()
        showing = nil
    }

    func letGo() { input.letGo() }

    // MARK: Following the host

    /// The host streams `active`: a source this Mac chose, or one the host picked (an app opened
    /// from the status item streams its new window). The window for it gets the picture, made if
    /// there is none.
    /// The host's source as this Mac's windows know it: on a host that lists its displays, the Desktop is
    /// the Desktop window of the display it shows (DesktopWindow), one window per display.
    func local(_ source: StreamSource) -> StreamSource {
        guard source == .desktop, !client.hostDisplays.isEmpty, let d = client.desktopDisplay else { return source }
        return .window(DesktopWindow.id(display: d))
    }

    /// The display a Desktop window shows; nil for the other Mac's windows.
    private func display(of source: StreamSource) -> DisplayInfo? {
        guard case .window(let id) = source, let d = DesktopWindow.display(of: id) else { return nil }
        return client.hostDisplays.first { $0.id == d }
    }

    private func activeChanged(_ active: StreamSource) {
        windowLog("host streams \(active) (requested \(String(describing: requested)), showing \(String(describing: showing)))")
        guard client.connected, active != .none else { return }
        // A focus the host dropped while it switched: asked for again, once its list has come.
        if let wanted = requested, wanted != active, (NSApp.keyWindow as? StreamWindow)?.source == wanted, open[wanted] != nil {
            pick(wanted)
            return
        }
        requested = nil
        input.flushHeld()
        if open[active] == nil { open(active) }
        attach(to: active)
        requestSideStreams()
    }

    /// A window the host no longer lists has closed there (a moment's absence is the host's to wait
    /// out: it lists a window again within a poll): its window here closes too.
    private func windowsChanged(_ list: [WindowInfo]) {
        let ids = Set(list.map(\.id))
        // New windows of an app open here open by themselves: in front when the app is the one in use.
        if let seen = known, client.connected {
            let openApps = Set(open.keys.compactMap { source -> String? in
                guard case .window(let id) = source else { return nil }
                return client.windows.first { $0.id == id }?.bundleID ?? appOf[id]
            })
            let focusedApp: String? = {
                guard case .window(let id)? = (NSApp.keyWindow as? StreamWindow)?.source else { return nil }
                return appOf[id]
            }()
            // Not an app's untitled strips (a browser's full-screen bar, 115 points tall across the display).
            for w in list where !seen.contains(w.id) && openApps.contains(w.bundleID) && w.width >= 80 && w.height >= 150
                                && !w.title.isEmpty {
                open(.window(w.id), focus: w.bundleID == focusedApp)
            }
        }
        known = (known ?? []).union(ids)
        restore()
        for app in dockLaunches { launchFromDock(app) }
        for w in list { appOf[w.id] = w.bundleID }
        defer { syncDock() }
        for (source, window) in open {
            guard case .window(let id) = source else { continue }
            if DesktopWindow.display(of: id) != nil {
                // A Desktop window: closes once its display is gone from the other Mac.
                if display(of: source) == nil, !client.hostDisplays.isEmpty { window.close() } else { window.title = title(source) }
                continue
            }
            if ids.contains(id) {
                window.title = title(source)
            } else {
                window.close()
            }
        }
    }

    private func thumbnailsChanged(_ thumbs: [UInt32: NSImage]) {
        for (source, window) in open where source != showing {
            if case .window(let id) = source, let image = thumbs[id] { window.placeholder.image = image }
        }
    }

    /// The stream view goes into `source`'s window, with the window's own viewport: a window
    /// streams 1:1 (the Mac window is sized to this one), the Desktop as it is.
    /// A press on a window in the background, waiting for the other Mac to stream it.
    private var heldPress: (source: StreamSource, at: NSPoint, when: Date)?

    private func attach(to source: StreamSource) {
        guard let window = open[source] else { return }
        defer {
            // The press that brought it forward, still held: it goes on there now (a drag out of a
            // window in the background starts with one press).
            if let held = heldPress, held.source == source {
                heldPress = nil
                if Date().timeIntervalSince(held.when) < 2, NSEvent.pressedMouseButtons & 1 != 0 {
                    windowLog("buttons: the press on \(source) in the background goes on there")
                    input.beginHeldPress(at: held.at)
                }
            }
        }
        showing = source
        if case .window = source, display(of: source) == nil { input.textScale = 1 } else { input.textScale = nil }
        if input.superview !== window.container {
            input.removeFromSuperview()
            input.frame = window.container.bounds
            input.autoresizingMask = [.width, .height]
            window.container.addSubview(input)
        }
        if window.isKeyWindow { window.makeFirstResponder(input) }
        input.sendViewportNow()
        updatePill()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? StreamWindow else { return }
        windowLog("key: \(window.source)")
        updatePill()
        syncDock()   // the Dock menu's ✓ follows the front window
        focused(window)
    }

    #if DEBUG
    /// -SillFlipTest: what the window becoming key does, without the app being in front (a test
    /// started over ssh cannot take the front from the person using the Mac).
    func flipTest(to source: StreamSource) {
        guard let window = open[source] else { return }
        windowLog("flip test: \(source)")
        window.orderFront(nil)
        focused(window)
    }

    /// WindowBridge prototype: the window's size, its screen's scale and the decoded picture's, so a
    /// run without the screen in front can say whether the picture shows 1:1.
    func debugReport(_ source: StreamSource) {
        guard let window = open[source] else { windowLog("report: \(source) not open"); return }
        let content = window.contentLayoutRect.size, video = input.display.videoSize, rect = input.display.videoRect
        windowLog("report: \(source) window content \(Int(content.width))×\(Int(content.height)) pt at \(window.backingScaleFactor)x, "
                  + "decoded \(Int(video.width))×\(Int(video.height)) px, drawn \(Int(rect.width))×\(Int(rect.height)) pt "
                  + "(\(rect.width > 0 ? String(format: "%.3f", video.width / rect.width) : "–") px per pt)")
    }
    #endif

    private func focused(_ window: StreamWindow) {
        window.container.endBackgroundScroll()
        if local(client.active) != window.source {
            window.placeholder.image = thumbnail(window.source) ?? window.placeholder.image
            pick(window.source)
        } else {
            attach(to: window.source)
        }
    }

    /// Asks the host for `source`: the stream view goes into its window (for the pointer's geometry),
    /// a viewport with no scale goes first (the host fits the window it picks to the last viewport,
    /// which was another window's), and the window's own size once the host has switched (`attach`).
    private func pick(_ source: StreamSource) {
        windowLog("pick \(source) (window: \(open[source] != nil), active \(client.active))")
        guard let window = open[source] else { return }
        requested = source
        showing = source
        if input.superview !== window.container {
            input.removeFromSuperview()
            input.frame = window.container.bounds
            input.autoresizingMask = [.width, .height]
            window.container.addSubview(input)
        }
        if window.isKeyWindow { window.makeFirstResponder(input) }
        input.textScale = nil
        input.sendViewportNow()
        ask(source)
        watchPick(source, tries: 0)
    }

    /// The host asked for `source`: a Desktop window is the Desktop on its display.
    private func ask(_ source: StreamSource) {
        if let d = display(of: source) {
            if client.desktopDisplay != d.id { client.pickDisplay(d.id) }
            client.select(.desktop)
        } else {
            client.select(source)
        }
    }

    /// A pick the host has not taken (it was switching, or the message went with a connection that
    /// moved) never changes `active`, so nothing would end the hold and every key would wait and be
    /// dropped: asked again after 1.5 s, twice, then input goes to whatever streams.
    private func watchPick(_ source: StreamSource, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.requested == source, self.local(self.client.active) != source, self.client.connected else { return }
            if tries < 2, self.open[source] != nil {
                windowLog("pick \(source) not taken after 1.5 s; asking again")
                self.ask(source)
                self.watchPick(source, tries: tries + 1)
            } else {
                windowLog("pick \(source) never taken; input goes on to \(self.client.active)")
                self.requested = nil
                self.input.dropHeld()   // made for the window that never came: never typed into another
            }
        }
    }


    func windowDidResignKey(_ notification: Notification) { updatePill() }
    func windowDidMiniaturize(_ notification: Notification) { updatePill(); syncDock(); requestSideStreams() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePill(); syncDock(); requestSideStreams() }
    /// Covered or uncovered, on screen or off (another Space, the display asleep): a window no one
    /// can see is paused on the host.
    func windowDidChangeOcclusionState(_ notification: Notification) { requestSideStreams() }
    func windowDidEnterFullScreen(_ notification: Notification) { updatePill() }
    func windowDidExitFullScreen(_ notification: Notification) { updatePill() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? StreamWindow else { return }
        open[window.source] = nil
        window.forgetPicture()
        if let id = Self.sideID(window.source) { fullSpeed.removeAll { $0 == id } }
        router.register(window.source, nil)
        if case .window(let id) = window.source { sideFeeds.set(id, nil) }
        defer { requestSideStreams(); syncDock(); keep() }
        guard showing == window.source else { return }
        input.letGo()
        input.removeFromSuperview()
        showing = nil
        // The next window of the other Mac's takes the stream, or nothing streams.
        if let next = NSApp.orderedWindows.compactMap({ $0 as? StreamWindow }).first(where: { $0 !== window && !$0.isMiniaturized }) {
            next.makeKeyAndOrderFront(nil)
        } else if client.connected {
            client.select(.none)
        }
    }

    /// Moved to another of this Mac's displays: its rate (120 Hz or 60) and, full screen, its size
    /// are that display's, so the host's desk display for the window follows (a new viewport: the
    /// host makes the desk display again when it must grow, at the new rate).
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? StreamWindow, window.source == showing else { return }
        input.sendViewport(after: 0.1)
    }

    func windowDidResize(_ notification: Notification) {
        pill.place()
        guard let window = notification.object as? StreamWindow, window.source == showing else { return }
        input.sendViewport(after: 0.25)
    }

    // MARK: Helpers

    private func initialSize(_ source: StreamSource) -> NSSize {
        let room = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
        var size: NSSize
        switch source {
        case .window(let id) where DesktopWindow.display(of: id) != nil:
            let d = display(of: source)
            size = NSSize(width: CGFloat(d?.width ?? 1440), height: CGFloat(d?.height ?? 900))
        case .window(let id):
            let w = client.windows.first { $0.id == id }
            size = NSSize(width: CGFloat(w?.width ?? 1000), height: CGFloat(w?.height ?? 700))
        default:
            // The Desktop: the frame's shape when known, else 16:10.
            let video = client.videoSize
            size = video.width > 0 && client.active == .desktop
                ? NSSize(width: 1280, height: 1280 * video.height / video.width)
                : NSSize(width: 1280, height: 800)
        }
        let fit = min(1, (room.width - 40) / size.width, (room.height - 40) / size.height)
        return NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
    }

    func title(_ source: StreamSource) -> String {
        if let d = display(of: source) { return "\(client.macName) — \(d.name)" }
        switch source {
        case .window(let id):
            guard let w = client.windows.first(where: { $0.id == id }) else { return client.macName }
            return w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)"
        case .desktop: return "\(client.macName) — Desktop"
        case .none: return client.macName
        }
    }

    private func thumbnail(_ source: StreamSource) -> NSImage? {
        if case .window(let id) = source { return client.thumbnails[id] }
        return nil
    }
}

/// The other Mac's windows by ID, each with its side stream's decoder, for the network queue.
final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt32: HEVCSampleFeed] = [:]
    func get(_ id: UInt32) -> HEVCSampleFeed? { lock.lock(); defer { lock.unlock() }; return map[id] }
    func set(_ id: UInt32, _ feed: HEVCSampleFeed?) { lock.lock(); map[id] = feed; lock.unlock() }
    func removeAll() { lock.lock(); map.removeAll(); lock.unlock() }
}

/// A window's own picture while it is not the main stream: its side stream, decoded by its own layer.
final class SideView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private(set) lazy var feed = HEVCSampleFeed(layer: displayLayer)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(displayLayer)
        _ = feed
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

/// A stream window's content: takes files dropped on the picture (the focused window's own view
/// takes them first), as the point they were let go at, a fraction of the picture from its top left.
final class DropContainer: NSView {
    var onDrop: ((NSDraggingInfo, CGPoint) -> Bool)?
    /// What a drop would do at that point (a fraction of the picture from its top left).
    var over: ((NSDraggingInfo, CGPoint) -> NSDragOperation)?
    var exited: ((NSDraggingInfo) -> Void)?
    /// A press on the picture of a window in the background (the stream view is elsewhere): the
    /// window comes forward, and the press goes on once the other Mac streams it.
    var onBackgroundPress: ((NSEvent) -> Void)?
    /// Input over the picture of a window in the background that does not bring it forward, as on a
    /// Mac: a scroll, and the pointer moving over it (a fraction of the picture from its top left).
    var onBackgroundInput: ((InputEvent) -> Void)?
    private var scrollState = ScrollState()
    /// The stream view, while it is in this window (`StreamInputView`).
    private var input: StreamInputView? { subviews.lazy.compactMap { $0 as? StreamInputView }.first }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if input != nil { return super.hitTest(point) }
        return frame.contains(point) ? self : nil   // the picture and placeholder take no presses of their own
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let input { input.mouseDown(with: event) } else { onBackgroundPress?(event) }
    }
    // The press began here: its drag and its up go to the stream view once it has come (it ignores
    // them until the held press is begun, `beginHeldPress`).
    override func mouseDragged(with event: NSEvent) { input?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { input?.mouseUp(with: event) }

    /// A scroll begun while this window was in the background ends there (the window came forward).
    func endBackgroundScroll() {
        for e in scrollState.finish() { onBackgroundInput?(e) }
    }

    override func scrollWheel(with event: NSEvent) {
        if let input {
            endBackgroundScroll()
            input.scrollWheel(with: event)
            return
        }
        guard let p = pictureFraction(event) else { return }
        for e in scrollState.events(for: event, at: p, picture: bounds.size) { onBackgroundInput?(e) }
    }
    override func mouseMoved(with event: NSEvent) {
        guard input == nil, let p = pictureFraction(event) else { return }   // the stream view tracks its own
        onBackgroundInput?(.pointer(.move, x: Double(p.x), y: Double(p.y)))
    }
    /// The picture fills the window, the other Mac's window at 1:1.
    private func pictureFraction(_ event: NSEvent) -> CGPoint? {
        let at = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0, bounds.contains(at) else { return nil }
        return CGPoint(x: at.x / bounds.width, y: isFlipped ? at.y / bounds.height : 1 - at.y / bounds.height)
    }
    // Moves while the window is in the background too.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { at(sender).flatMap { over?(sender, $0) } ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { at(sender).flatMap { over?(sender, $0) } ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { if let sender { exited?(sender) } }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let p = at(sender) else { return false }
        return onDrop?(sender, p) ?? false
    }
    private func at(_ sender: NSDraggingInfo) -> CGPoint? {
        let p = convert(sender.draggingLocation, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(x: min(max(p.x / bounds.width, 0), 1), y: min(max(1 - p.y / bounds.height, 0), 1))
    }
}

/// One of the other Mac's windows: its picture at 1:1, filling a window with no frame of its own.
final class StreamWindow: NSWindow {
    let source: StreamSource
    let container = DropContainer()
    let placeholder = NSImageView()
    let side = SideView()
    /// Minimise, handed to its app's Dock icon (StreamWindows.park): true if taken, else macOS minimises it.
    var onMinimize: ((StreamWindow) -> Bool)?
    /// Its last picture while it is minimised into its app's Dock icon.
    var parkedPicture: String?
    var parked: Bool { parkedPicture != nil }

    override func miniaturize(_ sender: Any?) {
        if onMinimize?(self) != true { super.miniaturize(sender) }
    }

    func forgetPicture() {
        if let path = parkedPicture { try? FileManager.default.removeItem(atPath: path) }
        parkedPicture = nil
    }

    init(source: StreamSource, size: NSSize) {
        self.source = source
        // No frame of its own: the picture fills it, title bar included. This Mac's controls are the
        // pill above it (WindowPill); the other Mac's title bar and buttons, with that Mac's own
        // window menu, are in the picture.
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        collectionBehavior.insert(.fullScreenPrimary)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(kind)?.isHidden = true }
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        backgroundColor = .black
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.frame = container.bounds
        placeholder.autoresizingMask = [.width, .height]
        // An NSImageView registers for file and image drags itself and, not editable, refuses them;
        // as the deepest view under the pointer it took every drop meant for the container.
        placeholder.unregisterDraggedTypes()
        container.addSubview(placeholder)
        side.frame = container.bounds
        side.autoresizingMask = [.width, .height]
        container.addSubview(side)
        contentView = container
    }
}
