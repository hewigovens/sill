import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import StreamProtocol

/// The windows streamed besides the one picked (kinds 29–31; the Mac client shows each of the host's
/// windows as a window of its own, all of them live). Each is captured and encoded on its own at a
/// lower rate (SideStreamRequest: 15 fps unless asked otherwise, 30 at most), at the stream's
/// capture scale, sharing the Mac's encoder engine with the main stream; the main stream never
/// waits for them, because the server drops a side frame rather than queue it behind anything
/// (StreamServer.sendSide). A window the main stream shows is never also a side stream, a window
/// that changes size is started again at its new size, and one whose capture or encoder fails is
/// left alone for 10 s. At most `maxWindows` at once, the first asked first. Nothing is captured
/// for a device that asks for none. Main actor.
@MainActor
final class SideStreams {
    static let maxWindows = 6

    private final class Stream {
        let id: UInt32
        let size: CGSize
        let fps: Int
        /// Its capture and encode scale: the stream's, or 1× in the background (not at full speed).
        let scale: CGFloat
        /// The window's frame when it was cropped from its display (wholeApp), to tell when it moved.
        var cropFrame: CGRect?
        /// The share pill macOS draws while the window itself is captured (SharePill).
        var pill: SharePill?
        /// On Sill's desk (DeskStages).
        var onDesk = false
        /// Whether whole-app capture was asked for when it started: a change restarts it.
        var wholeApp = false
        /// Its window was off screen when it started (captured alone for that): tried again once it shows.
        var offScreen = false
        let startedAt = Date()
        let capture = WindowCapture()
        var encoder: HEVCEncoder?
        init(id: UInt32, size: CGSize, fps: Int, scale: CGFloat) { self.id = id; self.size = size; self.fps = fps; self.scale = scale }
    }

    private let server: StreamServer
    private let catalog: WindowCatalog
    /// The stream's capture scale, the encoder to use and the bitrate per 60 fps, read at each start.
    var settings: () -> (scale: CGFloat, software: Bool, bitratePer60: Int, prioritizeSpeed: Bool) = { (2, false, 15_000_000, false) }
    /// The main stream's rate, for a window a device wants at full speed (`SideStreamRequest.fullRate`).
    var mainFPS: () -> Int = { 60 }
    /// The window the main stream shows, if it is one.
    var mainWindow: () -> UInt32? = { nil }
    /// Sill's desk, where a whole-app device's windows live (nil: none, a test host).
    var desk: () -> DeskStages? = { nil }
    /// WindowServer delivers no display stream (StreamCoordinator.displayStreamsDead): every window
    /// is captured alone, a full-screen one and one cropped with its app too.
    var displayStreamsDead: () -> Bool = { false }

    private var wanted: [ObjectIdentifier: (connection: NWConnection, windows: [UInt32], fps: Int, wholeApp: Bool, screen: CGSize?,
                                               fullRate: Set<UInt32>, paused: Set<UInt32>)] = [:]
    /// The largest screen of the devices that asked (Sill's desk makes each window's room that big).
    var largestScreen: CGSize? {
        wanted.values.compactMap(\.screen).max { $0.width * $0.height < $1.width * $1.height }
    }
    /// Some device asks for windows captured with what belongs to them (StreamCoordinator's main
    /// stream follows it too).
    var wholeApp: Bool { wanted.values.contains { $0.wholeApp } }
    /// The devices that asked for whole-app capture: the Mac clients.
    var wholeAppConnections: [NWConnection] { wanted.values.filter(\.wholeApp).map(\.connection) }
    /// The devices' wish for whole-app capture changed: the main stream starts again with it.
    var onWholeAppChanged: (() -> Void)?
    /// The person at this Mac stopped the sharing (StreamCoordinator.sharingStopped).
    var onStoppedByPerson: (() -> Void)?
    private var streams: [UInt32: Stream] = [:]
    private var failedAt: [UInt32: Date] = [:]
    private var reconciling = false
    private var again = false
    /// The encoders by window, for the server's keyframe requests on its network queue.
    private let encoders = EncoderBox()

    init(server: StreamServer, catalog: WindowCatalog) {
        self.server = server
        self.catalog = catalog
        let box = encoders
        server.onSideKeyframeNeeded = { id in box.get(id)?.requestKeyframe() }
    }

    /// Whether any device wants `id` at full speed (`SideStreamRequest.fullRate`).
    func wantsFullRate(_ id: UInt32) -> Bool { wanted.values.contains { $0.fullRate.contains(id) } }

    func request(_ r: SideStreamRequest, from c: NWConnection) {
        let fps = min(max(r.fps ?? SideStreamRequest.defaultFPS, 1), SideStreamRequest.maxFPS)
        let full = Set((r.fullRate ?? []).prefix(SideStreamRequest.maxFullRate))
        let paused = Set(r.paused ?? [])
        var seen = Set<UInt32>()
        let windows = r.windows.filter { seen.insert($0).inserted }
        let before = wholeApp
        // Kept with no windows when it asks for whole-app capture: the main stream follows that.
        if windows.isEmpty && r.wholeApp != true { wanted[ObjectIdentifier(c)] = nil }
        else {
            let screen = r.screen.flatMap { $0.count == 2 && $0[0] > 0 && $0[1] > 0 ? CGSize(width: $0[0], height: $0[1]) : nil }
            wanted[ObjectIdentifier(c)] = (c, windows, fps, r.wholeApp == true, screen, full, paused)
        }
        if wholeApp != before { onWholeAppChanged?() }
        Task { await reconcile() }
    }

    func clientLeft(_ c: NWConnection) {
        let before = wholeApp
        guard wanted.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        if wholeApp != before { onWholeAppChanged?() }
        Task { await reconcile() }
    }

    /// The catalog changed (sizes, windows gone) or the main stream did.
    func changed() { Task { await reconcile() } }

    /// The windows streaming beside the main one now.
    var streaming: [UInt32] { Array(streams.keys) }

    /// `ids` no longer asked for by any device until it asks again (the person at the Mac took them back).
    func forget(_ ids: Set<UInt32>) {
        for (key, entry) in wanted {
            wanted[key] = (entry.connection, entry.windows.filter { !ids.contains($0) }, entry.fps, entry.wholeApp, entry.screen,
                           entry.fullRate, entry.paused)
        }
        Task { await reconcile() }
    }

    /// Every running stream stopped, what the devices ask for kept: the desk's captures start again
    /// (`StreamCoordinator.refreshDesk`), and `changed()` starts them again.
    func stopStreams() async {
        for id in Array(streams.keys) { await stop(id) }
    }

    /// Every capture stopped, waited for: the exit path, before the desk's displays go.
    func stopCapturesNow(timeout: TimeInterval) {
        for stream in streams.values {
            stream.capture.stopNow(timeout: timeout)
            stream.pill?.stopNow(timeout: timeout)
        }
    }

    /// Brings the running streams to what is asked: one at a time, a request made meanwhile runs after.
    func reconcile() async {
        if reconciling { again = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            again = false
            await reconcileOnce()
        } while again
    }

    private func reconcileOnce() async {
        let main = mainWindow()
        let now = Date()
        // The first asked first, over every device; the main stream's window never.
        var order: [UInt32] = []
        var fps: [UInt32: Int] = [:]
        var subscribers: [UInt32: [NWConnection]] = [:]
        // Full speed keeps a window at the stream's scale; every other one in the background is
        // encoded at 1× (a quarter of a Retina window's pixels: the one encoder goes further).
        var full: Set<UInt32> = []
        for entry in wanted.values {
            // A window the device cannot see now (minimised, covered) stays on the desk, unsent.
            for id in entry.windows where id != main && !entry.paused.contains(id) {
                if fps[id] == nil { order.append(id) }
                if entry.fullRate.contains(id) { full.insert(id) }
                // A window wanted at full speed: the main stream's rate (the device's, under this Mac's limit).
                fps[id] = max(fps[id] ?? 0, entry.fullRate.contains(id) ? max(entry.fps, mainFPS()) : entry.fps)
                subscribers[id, default: []].append(entry.connection)
            }
        }
        var target: [UInt32: SCWindow] = [:]
        // A Desktop window (DesktopWindow): one of this Mac's own displays, whole.
        var displays: [UInt32: SCDisplay] = [:]
        for id in order where target.count + displays.count < Self.maxWindows {
            if let failed = failedAt[id], now.timeIntervalSince(failed) < 10 { continue }
            if let d = DesktopWindow.display(of: id) {
                if let display = catalog.realDisplays.first(where: { $0.displayID == d }) { displays[id] = display }
                continue
            }
            guard let w = catalog.window(id: id), w.frame.width >= 32, w.frame.height >= 32 else { continue }
            target[id] = w
        }
        server.setSideSubscribers(subscribers.filter { target[$0.key] != nil || displays[$0.key] != nil })
        // The desk keeps what a device shows (side streams and the main window) and sends the rest home.
        if let desk = desk() {
            // Every window a device has open stays there, streaming or not: one whose side stream
            // failed to start, is over the limit, or is briefly off the window list while it moves
            // is still shown on the device, and sending it home would move it under the person at
            // this Mac and make its display again when it streams.
            var keep = Set(wanted.values.flatMap(\.windows))
            if let main { keep.insert(main) }
            if !wholeApp { keep = [] }   // no device asks for it any more: every window goes home
            // A capture still running on a display as it is removed left WindowServer's display streams
            // delivering nothing, for every app, until it restarted (macOS 27.0.1): stopped first.
            for id in Array(streams.keys) where DesktopWindow.display(of: id) == nil && !keep.contains(id) { await stop(id) }
            desk.keep(keep)
        }
        let scaleOf = { (id: UInt32) -> CGFloat in full.contains(id) ? self.settings().scale : min(self.settings().scale, 1) }
        for (id, stream) in streams where DesktopWindow.display(of: id) != nil {
            let size = displays[id].map { CGDisplayBounds($0.displayID).size }
            if size != stream.size || fps[id] != stream.fps || scaleOf(id) != stream.scale { await stop(id) }
        }
        for (id, d) in displays where streams[id] == nil {
            await start(display: d, id: id, fps: fps[id] ?? SideStreamRequest.defaultFPS, scale: scaleOf(id))
        }
        for (id, stream) in streams where DesktopWindow.display(of: id) == nil {
            let w = target[id]
            let moved = stream.cropFrame.map { $0.origin != w?.frame.origin } ?? false
            // Captured alone because its window was off screen when it started: tried again once the
            // window shows, at most every 30 s (alone for another reason, the desk's refusal, it stays).
            let retry = stream.offScreen && !stream.onDesk && stream.cropFrame == nil && w?.isOnScreen == true && Date().timeIntervalSince(stream.startedAt) > 30
            if w == nil || w!.frame.size != stream.size || fps[id] != stream.fps || moved || scaleOf(id) != stream.scale
                || stream.wholeApp != wholeApp || retry { await stop(id) }
        }
        for (id, w) in target where streams[id] == nil {
            await start(w, fps: fps[id] ?? SideStreamRequest.defaultFPS, scale: scaleOf(id))
        }
    }

    /// A Desktop window's side stream: the display whole, at the stream's scale.
    private func start(display d: SCDisplay, id: UInt32, fps: Int, scale: CGFloat) async {
        let s = settings()
        let size = CGDisplayBounds(d.displayID).size
        let width = evenPixels(size.width * scale), height = evenPixels(size.height * scale)
        let bitrate = max(2_000_000, s.bitratePer60 * fps / 60)
        let stream = Stream(id: id, size: size, fps: fps, scale: scale)
        do {
            let enc = try HEVCEncoder(width: width, height: height, fps: fps, bitrate: bitrate, prioritizeSpeed: s.prioritizeSpeed,
                                      software: s.software, quiet: true)
            let server = self.server
            enc.onEncoded = { data, isKey, ps in server.sendSide(window: id, parameterSets: ps?.encoded(), frame: data, isKeyframe: isKey) }
            enc.onHung = { [weak self] in
                Task { @MainActor in
                    guard let self, self.streams[id] != nil else { return }
                    self.failedAt[id] = Date()
                    await self.stop(id)
                }
            }
            stream.capture.statsPrefix = "side.cap"
            stream.capture.onFrame = { pb, pts in enc.encode(pb, pts: pts) }
            stream.capture.onStopped = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.streams[id] === stream else { return }
                    if StreamCoordinator.stoppedByPerson(error) { self.onStoppedByPerson?(); return }
                    self.failedAt[id] = Date()
                    await self.stop(id)
                }
            }
            stream.encoder = enc
            streams[id] = stream
            encoders.set(id, enc)
            try await stream.capture.start(filter: SCContentFilter(display: d, excludingWindows: []), width: width, height: height,
                                           fps: fps, showsCursor: false)
            print("Side stream: display \(d.displayID) (a Desktop window) at \(width)×\(height), \(fps) fps, \(bitrate / 1_000_000) Mbps")
        } catch {
            print("Side stream of display \(d.displayID) did not start: \(error)")
            failedAt[id] = Date()
            if streams[id] === stream { streams[id] = nil; encoders.set(id, nil) }
        }
    }

    private func start(_ w: SCWindow, fps: Int, scale streamScale: CGFloat) async {
        let id = w.windowID
        let s = settings()
        let stream = Stream(id: id, size: w.frame.size, fps: fps, scale: streamScale)
        // Registered before anything waits, so a reconcile meanwhile sees it starting.
        streams[id] = stream
        do {
            // Where it is captured, and so the picture's size, decided first: the encoder is made at
            // that size. Made at the window's reported size instead, a full-screen window captured as
            // its display's band (1920×840 where the window said 1920×1198) was stretched tall on the
            // device (2026-10-13).
            var staged: (filter: SCContentFilter, sourceRect: CGRect, size: CGSize)?
            if wholeApp, let desk = desk() {
                do { staged = try await desk.prepare(w, size: w.frame.size, captureScale: s.scale, fps: nil, room: largestScreen) }
                catch { print("Sill's desk: window \(id) could not move there (\(error)); capturing it where it is.") }
            }
            guard streams[id] === stream else { return }   // stopped while it was being placed
            var plan: (filter: SCContentFilter, sourceRect: CGRect?, width: Int, height: Int)
            var crop: (frame: CGRect, filter: SCContentFilter, sourceRect: CGRect)?
            if let staged {
                stream.onDesk = true
                // A window in the background is captured on its own (its menus are for when it is the
                // main stream); window capture shows the system's share pill by itself. Full screen,
                // its display is captured instead: the window an app reports then can be far wider
                // than its Space (a browser's: 3768 pt on a 1712 pt display), and fitted into the frame
                // the video was a quarter of it, in a corner (2026-10-12).
                let scale = min(streamScale, desk()?.scale(for: id) ?? streamScale)
                let width = evenPixels(staged.size.width * scale), height = evenPixels(staged.size.height * scale)
                plan = desk()?.isFullScreen(id) == true && !displayStreamsDead()
                    ? (staged.filter, staged.sourceRect, width, height)
                    : (SCContentFilter(desktopIndependentWindow: w), nil, width, height)
            } else if wholeApp, !displayStreamsDead(), w.isOnScreen, let found = await AppCrop.crop(for: w) {
                // On screen only: cropped from its display, a window in another Space showed what
                // lay there instead (other apps' windows), not itself.
                crop = (found.frame, found.filter, found.sourceRect)
                let scale = windowCaptureScale(streamScale, windowScale: found.filter.pointPixelScale)
                plan = (found.filter, found.sourceRect, evenPixels(w.frame.width * scale), evenPixels(w.frame.height * scale))
            } else {
                // At the window's own scale at most: a 1× window at 2× fills only the top-left quarter.
                let inPlace = SCContentFilter(desktopIndependentWindow: w)
                let scale = windowCaptureScale(streamScale, windowScale: inPlace.pointPixelScale)
                plan = (inPlace, nil, evenPixels(w.frame.width * scale), evenPixels(w.frame.height * scale))
            }
            let width = plan.width, height = plan.height
            // A window at full speed runs at the main stream's rate: capped at its size as that is.
            let fps = StreamRate.capped(fps, pixels: width * height, software: s.software)
            let bitrate = max(2_000_000, s.bitratePer60 * fps / 60)
            let enc = try HEVCEncoder(width: width, height: height, fps: fps, bitrate: bitrate, prioritizeSpeed: s.prioritizeSpeed,
                                      software: s.software, quiet: true)
            let server = self.server
            enc.onEncoded = { data, isKey, ps in server.sendSide(window: id, parameterSets: ps?.encoded(), frame: data, isKeyframe: isKey) }
            enc.onHung = { [weak self] in
                Task { @MainActor in
                    guard let self, self.streams[id] != nil else { return }
                    print("Side stream of window \(id): the encoder stopped answering; leaving it for 10 s.")
                    self.failedAt[id] = Date()
                    await self.stop(id)
                }
            }
            stream.capture.statsPrefix = "side.cap"
            stream.capture.onFrame = { pb, pts in enc.encode(pb, pts: pts) }
            stream.capture.onStopped = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.streams[id] === stream else { return }
                    if StreamCoordinator.stoppedByPerson(error) { self.onStoppedByPerson?(); return }
                    self.failedAt[id] = Date()
                    await self.stop(id)
                }
            }
            stream.encoder = enc
            stream.wholeApp = wholeApp
            stream.offScreen = wholeApp && !w.isOnScreen
            encoders.set(id, enc)
            if let crop {
                stream.cropFrame = crop.frame
                let pill = SharePill()
                await pill.start(w)
                stream.pill = pill
            }
            try await stream.capture.start(filter: plan.filter, width: width, height: height, fps: fps, showsCursor: false,
                                           sourceRect: plan.sourceRect)
            print("Side stream: \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "") (window \(id)) at \(width)×\(height), \(fps) fps, \(bitrate / 1_000_000) Mbps\(stream.cropFrame != nil ? ", with its app" : "")")
        } catch {
            print("Side stream of window \(id) did not start: \(error)")
            failedAt[id] = Date()
            if streams[id] === stream { streams[id] = nil; encoders.set(id, nil) }
        }
    }

    private func stop(_ id: UInt32) async {
        guard let stream = streams.removeValue(forKey: id) else { return }
        encoders.set(id, nil)
        await stream.capture.stop()
        await stream.pill?.stop()
        stream.capture.onFrame = nil
        stream.encoder = nil   // its deinit drains and invalidates the session
    }

    /// Lock-protected, for the network queue.
    private final class EncoderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [UInt32: HEVCEncoder] = [:]
        func get(_ id: UInt32) -> HEVCEncoder? { lock.lock(); defer { lock.unlock() }; return map[id] }
        func set(_ id: UInt32, _ e: HEVCEncoder?) { lock.lock(); map[id] = e; lock.unlock() }
    }
}
