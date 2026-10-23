import AppKit
import SwiftUI
import StreamProtocol
import UniformTypeIdentifiers

/// The stream view and everything this Mac's mouse, trackpad and keyboard send through it. It hosts
/// the client's one `HEVCDisplayView` and turns NSEvents into the input the host already takes
/// (InputEvent, kind 8; gestures, kind 28), as the iOS app's overlay does for touches:
///
/// - The pointer: a move over the picture, a fraction of the frame; with a button down, clamped to
///   the frame, so a drag past the edge keeps going. Left, right and middle buttons (the middle one
///   only to a Mac that takes it); the host counts double and triple clicks itself.
/// - Scrolling: the trackpad's own phases and momentum, as the host expects from a trackpad
///   (began, deltas, ended, then momentumBegan, deltas, momentumEnded); a mouse wheel's bare deltas.
///   Deltas are a fraction of the frame as shown, in AppKit's sign, which is the wire's (positive
///   moves the content down or right).
/// - Keys: every key while the view has the keyboard, read before the menus see it (a local
///   monitor), so ⌘W and ⌘Q go to the Mac being controlled, not to this app; ⌘Tab, ⌘Space and the
///   other shortcuts macOS takes before any app only with Capture System Shortcuts (`SystemKeyTap`).
/// - Gestures: a swipe that reaches the app goes as the host's three-finger gesture; the Mac menu
///   (SillClientApp) sends each by name.
///
/// While the pointer is over the picture this Mac's own cursor takes the Mac's shape (kind 14), so
/// it moves at this Mac's rate with no round trip; the sprite shows only while the other Mac's
/// pointer is moved from there. Main thread.
final class StreamInputView: NSView {
    let client: StreamClient
    let display: HEVCDisplayView

    /// The keys and buttons this view has sent down and not up: let go when the view loses the
    /// keyboard or the session ends, so nothing stays held on the other Mac.
    private var keysDown: Set<UInt16> = []
    /// Typing through this Mac's input method (StreamInputView+TextInput.swift).
    let textInput = TextInputBridge()
    private var leftDown = false
    /// What an app on the other Mac is dragging under the held button (kind 36): carried out of the
    /// window, the drag goes on here with those files.
    var dragOffer: DragOffer?
    /// The files of the drag out under way (for a drop on the Trash).
    var outgoing: [FilePromises.Promise] = []
    /// The drag followed live on the other Mac (kind 38), when it takes that (StreamWindows sets it).
    var live: LiveDrop?
    /// The other Mac's window this view shows: nil for the Desktop (the streamed source).
    var sourceWindowID: UInt32? {
        if let w = window as? StreamWindow, case .window(let id) = w.source { return id }
        return nil
    }
    private var rightDown = false
    private var middleDown = false
    /// A scroll gesture under way (began sent, ended not), and its momentum.
    private var scrollState = ScrollState()
    private var keyMonitor: Any?
    private var buttonMonitor: Any?
    private var tracking: NSTrackingArea?
    private var viewportWork: DispatchWorkItem?
    /// The Aa scale for the Mac window (Viewport.scale): nil leaves the Mac window's size alone. Set
    /// by the window manager (StreamWindows), which sends the viewport itself.
    var textScale: Double?
    /// Whether a viewport may go now: only from the window the host streams (StreamWindows), since
    /// the host fits the window it streams to the last viewport it was sent.
    var viewportAllowed: () -> Bool = { true }

    init(client: StreamClient) {
        self.client = client
        self.display = client.displayView
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        display.removeFromSuperview()
        display.frame = bounds
        display.autoresizingMask = [.width, .height]
        addSubview(display)
        client.onCursorShapeChange = { [weak self] shape in
            guard let self else { return }
            self.display.setCursorShape(shape)
            self.window?.invalidateCursorRects(for: self)
        }
        display.setCursorShape(client.cursorShape)
        client.onPointerChange = { [weak self] p in self?.display.setPointer(p) }
        display.onVideoSizeChangedForInput = { [weak self] in
            guard let self else { return }
            self.client.pointerFrameChanged()
            self.window?.invalidateCursorRects(for: self)
            #if DEBUG
            MacInputTest.runIfAsked(self)   // -SillInputTest 1
            MacTextInputTest.runIfAsked(self)   // -SillTextInputTest 1
            #endif
        }
        client.renderPointer()
        // A button let go where this view never hears of it: the view moved to another window while
        // the button was held (the host switched streams under a press), so AppKit sent the up to
        // nowhere, and the other Mac kept the button down, every later click read as that button's
        // until it was pressed again (a left click acting as a right click). Every up in this app is
        // looked at first, and one the view would miss goes to the other Mac from here.
        buttonMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            self?.upSeen(event)
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A press made on this window while it was in the background, still held, now that the other Mac
    /// streams it: down there, at the point it was made (in window coordinates), and the drag goes on.
    func beginHeldPress(at locationInWindow: NSPoint) {
        guard !leftDown, let p = display.fraction(of: convert(locationInWindow, from: nil)) else { return }
        leftDown = true
        send(.move, p)
        send(.leftDown, p)
    }

    /// An up this view will not get (another window's, or none now that it moved): sent from here.
    private func upSeen(_ event: NSEvent) {
        guard event.window == nil || event.window !== window else { return }   // its own: its handler sends it
        let p = fraction(event, clamped: true) ?? .zero
        switch event.type {
        case .leftMouseUp where leftDown:
            leftDown = false; dragOffer = nil
            windowLog("buttons: the left button came up in another window; sent")
            send(.leftUp, p)
        case .rightMouseUp where rightDown:
            rightDown = false
            windowLog("buttons: the right button came up in another window; sent")
            send(.rightUp, p)
        case .otherMouseUp where middleDown && event.buttonNumber == 2:
            middleDown = false
            windowLog("buttons: the middle button came up in another window; sent")
            send(.middleUp, p)
        default:
            break
        }
    }

    /// Buttons this view thinks are down that this Mac has let go of (their up went to no app at all,
    /// as when the app was switched away from mid-press): let go of on the other Mac too.
    private func reconcileButtons() {
        let pressed = NSEvent.pressedMouseButtons
        if leftDown, pressed & 1 == 0 { leftDown = false; windowLog("buttons: left up never came; sent"); send(.leftUp, .zero) }
        if rightDown, pressed & 2 == 0 { rightDown = false; windowLog("buttons: right up never came; sent"); send(.rightUp, .zero) }
        if middleDown, pressed & 4 == 0 { middleDown = false; windowLog("buttons: middle up never came; sent"); send(.middleUp, .zero) }
    }

    override var acceptsFirstResponder: Bool { true }
    /// Clicks go to the other Mac; the window moves by its pill (WindowPill) or a drag in the picture's title strip.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { stopKeys(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        window.makeFirstResponder(self)
        // AppKit asks for tracking areas only when the geometry changes; a view put in a window at its
        // final size would otherwise get no mouseMoved at all (hover went unsent from the laptop).
        updateTrackingAreas()
        window.acceptsMouseMovedEvents = true
        startKeys()
        sendViewport(after: 0)
    }

    override func layout() {
        super.layout()
        sendViewport(after: 0.25)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Viewport

    /// The picture's room in points, the Mac window's scale and this screen's rate, a quarter of a
    /// second after the window last changed size (the host restarts its stream for each).
    func sendViewport(after delay: Double) {
        viewportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewportAllowed() else { return }
            self.sendViewportNow()
        }
        viewportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The viewport now, with `textScale` as it is: before a pick, with no scale, so the host resizes
    /// nothing while it switches.
    func sendViewportNow() {
        viewportWork?.cancel()
        guard client.connected, bounds.width > 0, bounds.height > 0 else { return }
        client.sendViewport(Viewport(width: Double(bounds.width), height: Double(bounds.height), scale: textScale,
                                     fps: StreamClient.wantedFPS(remote: client.awayCapsFrameRate)))
    }

    // MARK: Holding input through a switch

    /// Whether the host is still switching to this view's window (StreamWindows): input made now
    /// would land in the window it streamed before, the other app's, so it waits.
    var holding: () -> Bool = { false }
    private var held: [InputEvent] = []
    private var heldSince: Double?

    /// Every input this view makes: sent, or held while the host switches (at most 2 s, then dropped
    /// rather than typed into the wrong app). Pointer moves held collapse to the latest.
    func emit(_ event: InputEvent) {
        guard !LocalHostInput.current else { return }   // this Mac's own host posted it: never back out
        guard holding() else { client.sendInput(event); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = heldSince, now - since > 2 { held.removeAll(); heldSince = nil }
        if heldSince == nil { heldSince = now }
        if case .pointer(.move, _, _) = event, case .pointer(.move, _, _)? = held.last { held.removeLast() }
        if held.count < 500 { held.append(event) }
    }

    /// What waited for a switch that never came: dropped.
    func dropHeld() {
        held.removeAll()
        heldSince = nil
    }

    /// The host has switched to this view's window: what waited goes, in order.
    func flushHeld() {
        let events = held
        held.removeAll()
        heldSince = nil
        events.forEach { client.sendInput($0) }
    }

    // MARK: The cursor

    override func resetCursorRects() {
        let rect = display.videoRect
        guard rect.width > 0 else { return }
        addCursorRect(rect, cursor: Self.cursor(for: client.cursorShape))
    }

    /// The other Mac's cursor shape as this Mac's cursor, at the same size in points.
    static func cursor(for shape: StreamClient.CursorShape?) -> NSCursor {
        guard let shape, shape.size.width > 0, shape.size.height > 0 else { return .arrow }
        let image = shape.image.copy() as! NSImage
        image.size = shape.size
        return NSCursor(image: image, hotSpot: shape.hotspot)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func fraction(_ event: NSEvent, clamped: Bool) -> CGPoint? {
        display.fraction(of: convert(event.locationInWindow, from: nil), clamped: clamped)
    }

    private func send(_ action: PointerAction, _ p: CGPoint) {
        emit(.pointer(action, x: Double(p.x), y: Double(p.y)))
    }

    override func mouseMoved(with event: NSEvent) {
        reconcileButtons()   // a move with no button held: none can be down
        let p = fraction(event, clamped: false)
        setCursor(over: p != nil)
        guard let p else { return }
        send(.move, p)
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor(over: fraction(event, clamped: false) != nil)
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Over the picture, the other Mac's cursor shape (kind 14); elsewhere this Mac's arrow. Set on
    /// every move as well as by the cursor rect: a SwiftUI host can reset the cursor under it.
    private func setCursor(over picture: Bool) {
        (picture ? Self.cursor(for: client.cursorShape) : NSCursor.arrow).set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard leftDown, let p = fraction(event, clamped: true) else { return }
        // Files an app on the other Mac is dragging, carried out of this window: the drag goes on here.
        if let offer = dragOffer, !offer.files.isEmpty, !overOwnWindow() {
            dragOut(offer, event: event, last: p)
            return
        }
        send(.move, p)
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard rightDown, let p = fraction(event, clamped: true) else { return }
        send(.move, p)
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard middleDown, let p = fraction(event, clamped: true) else { return }
        send(.move, p)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startKeys()   // a click on the picture always gives it the keyboard, the keys handed back by ⌃⌥⌘⎋ included
        // A window's own title bar, as on any Mac window: a drag in its top strip moves this window;
        // a click there (no drag) goes to the other Mac, where toolbar buttons and tabs sit.
        if let window = window as? StreamWindow, case .window = window.source,
           convert(event.locationInWindow, from: nil).y < Self.titleStrip, event.clickCount == 1,
           dragsWindow(window, from: event) { return }
        guard let p = fraction(event, clamped: false) else { return }
        commitComposition()   // a click elsewhere ends what is being composed, as in any text field
        noteClick(at: convert(event.locationInWindow, from: nil))
        leftDown = true
        send(.move, p)
        send(.leftDown, p)
    }
    /// The title bar strip: a unified toolbar's height, which a plain title bar's lies within.
    private static let titleStrip: CGFloat = 52

    /// Waits for the button to come up or the pointer to move 3 points: moved, the window is dragged;
    /// up first, it was a click, sent as one. True when either happened.
    private func dragsWindow(_ window: NSWindow, from down: NSEvent) -> Bool {
        let start = down.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if let p = fraction(down, clamped: false) { send(.move, p); send(.leftDown, p); send(.leftUp, p) }
                return true
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 3 {
                window.performDrag(with: down)
                return true
            }
        }
        return false
    }

    override func mouseUp(with event: NSEvent) {
        dragOffer = nil
        guard leftDown else { return }
        leftDown = false
        send(.leftUp, fraction(event, clamped: true) ?? .zero)
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = fraction(event, clamped: false) else { return }
        rightDown = true
        send(.move, p)
        send(.rightDown, p)
    }
    override func rightMouseUp(with event: NSEvent) {
        guard rightDown else { return }
        rightDown = false
        send(.rightUp, fraction(event, clamped: true) ?? .zero)
    }

    /// The middle button (button 2), only to a Mac that takes it (`WindowList.middleButton`): an
    /// older host could not decode the event. Other buttons (back, forward) have no place on the wire.
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard event.buttonNumber == 2, client.hostMiddleButton, let p = fraction(event, clamped: false) else { return }
        middleDown = true
        send(.move, p)
        send(.middleDown, p)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, middleDown else { return }
        middleDown = false
        send(.middleUp, fraction(event, clamped: true) ?? .zero)
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let rect = display.videoRect
        guard rect.width > 0, let p = fraction(event, clamped: true) else { return }
        for e in scrollState.events(for: event, at: p, picture: rect.size) { emit(e) }
    }

    // MARK: Gestures

    /// A swipe macOS hands the app (System Settings › Trackpad's "Swipe between pages"): the host's
    /// gesture of the same direction. Three-finger swipes macOS keeps for itself never get here; the
    /// Mac menu sends those.
    override func swipe(with event: NSEvent) {
        let gesture: TrackpadGestures.Gesture?
        if abs(event.deltaX) > abs(event.deltaY) {
            gesture = event.deltaX > 0 ? .swipeRight : (event.deltaX < 0 ? .swipeLeft : nil)
        } else {
            gesture = event.deltaY > 0 ? .swipeDown : (event.deltaY < 0 ? .swipeUp : nil)
        }
        if let gesture { client.sendGesture(gesture, fingers: 3) }
    }

    // MARK: Keys

    @objc private func windowKeyChanged() {
        if window?.isKeyWindow == true { startKeys() } else { stopKeys() }
    }

    override func resignFirstResponder() -> Bool {
        stopKeys()
        return true
    }
    override func becomeFirstResponder() -> Bool {
        startKeys()
        return true
    }

    /// Takes every key while this window is key and the view has the keyboard: the monitor sees them
    /// before the menus' key equivalents.
    private func startKeys() {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return }
        SystemKeyTap.shared.attach(self)   // each time: the switch or Accessibility may have changed since
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
            // The app's own way out of the keyboard, never sent: ⌃⌥⌘⎋ hands the keys back to this app
            // (its menus' shortcuts work again) until the stream is clicked.
            if event.type == .keyDown, event.keyCode == 53,
               event.modifierFlags.intersection([.control, .option, .command]) == [.control, .option, .command] {
                self.window?.makeFirstResponder(nil)
                return nil
            }
            // An input method composes here and sends committed text (StreamInputView+TextInput.swift).
            if self.routeThroughTextInput(event) { return nil }
            self.forward(event.type, keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.type == .keyDown && event.isARepeat)
            return nil
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        SystemKeyTap.shared.detach(self)
        letGo()
    }

    /// A key event, from the monitor or the system tap.
    func forward(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool, via: String = "monitor") {
        if via == "monitor", LocalHostInput.current { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillKeyLog") {
            let line = "keys: \(via) \(type == .keyDown ? "down" : type == .keyUp ? "up" : "flags") keycode \(keyCode) flags \(String(flags.rawValue, radix: 16)) → usage \(MacKeyMap.hidUsages[keyCode].map { String($0, radix: 16) } ?? "none")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        #endif
        guard let usage = MacKeyMap.hidUsages[keyCode] else { return }
        let modifiers = MacKeyMap.wireModifiers(flags)
        switch type {
        case .keyDown:
            keysDown.insert(usage)
            emit(.key(hidUsage: usage, down: true, modifiers: modifiers))
        case .keyUp:
            keysDown.remove(usage)
            emit(.key(hidUsage: usage, down: false, modifiers: modifiers))
        case .flagsChanged:
            guard let flag = MacKeyMap.modifierFlag[keyCode] else { return }
            if flag == .capsLock {
                // One event a press, the light's new state in the flags: a press of the key.
                emit(.key(hidUsage: usage, down: true, modifiers: modifiers))
                emit(.key(hidUsage: usage, down: false, modifiers: modifiers))
                return
            }
            // Down when this key's flag is set and it was not already down; an up otherwise. The
            // left and right keys share a flag: the other side's key held keeps it set.
            let down = flags.contains(flag) && !keysDown.contains(usage)
            if down { keysDown.insert(usage) } else { keysDown.remove(usage) }
            emit(.key(hidUsage: usage, down: down, modifiers: modifiers))
        default:
            break
        }
    }

    /// Every key and button this view has down goes up: the keyboard went elsewhere, or the session ended.
    func letGo() {
        resetTextInput()
        for usage in keysDown.sorted() {   // keys first, then the modifiers (0xE0 up) they were typed with
            client.sendInput(.key(hidUsage: usage, down: false, modifiers: 0))
        }
        keysDown.removeAll()
        if leftDown { leftDown = false; client.sendInput(.pointer(.leftUp, x: 0.5, y: 0.5)) }
        if rightDown { rightDown = false; client.sendInput(.pointer(.rightUp, x: 0.5, y: 0.5)) }
        if middleDown { middleDown = false; client.sendInput(.pointer(.middleUp, x: 0.5, y: 0.5)) }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let buttonMonitor { NSEvent.removeMonitor(buttonMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
}

/// The stream view in SwiftUI. The input view is kept by the session's model, so re-hosting it (a
/// toolbar change) never sends a new viewport or lets keys go.
struct StreamViewRepresentable: NSViewRepresentable {
    let view: StreamInputView
    func makeNSView(context: Context) -> StreamInputView { view }
    func updateNSView(_ nsView: StreamInputView, context: Context) {}
}

// MARK: Files dropped from this Mac

/// Files dragged from Finder (or any app) onto the other Mac's window: sent in parts (kind 34), then
/// dropped where they were let go (kind 35), and the app there takes them as a drop; a folder goes
/// as one zip, unpacked there. Only to a Mac that takes them (`hostFileDrop`).
extension StreamInputView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOver(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOver(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { if let sender { live?.exited(sender) } }

    /// Followed live where the other Mac takes that (LiveDrop): this Mac's files, or its own carried
    /// back over its window; else only this Mac's files, dropped where they are let go.
    private func dragOver(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let live, live.enabled {
            return live.over(sender, window: sourceWindowID, at: display.fraction(of: convert(sender.draggingLocation, from: nil), clamped: true) ?? .zero)
        }
        return acceptsDrop(sender) ? .copy : []
    }

    private func acceptsDrop(_ sender: NSDraggingInfo) -> Bool {
        client.hostFileDrop && client.connected && !LiveDrop.files(sender).isEmpty
            && display.fraction(of: convert(sender.draggingLocation, from: nil)) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let live, live.enabled {
            return live.drop(sender, window: sourceWindowID, at: display.fraction(of: convert(sender.draggingLocation, from: nil), clamped: true) ?? .zero)
        }
        let urls = LiveDrop.files(sender)
        guard client.hostFileDrop, !urls.isEmpty, let at = display.fraction(of: convert(sender.draggingLocation, from: nil)) else { return false }
        Self.send(urls, at: at, client: client)
        return true
    }

    /// The files' parts, then the drop at `at` (a fraction of the picture). Off the main thread.
    static func send(_ urls: [URL], at: CGPoint, client: StreamClient, window: UInt32? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (ids, folders, total) = upload(urls, client: client)
            guard !ids.isEmpty else { return }
            client.send(.fileDrop, payload: Wire.encode(FileDrop(files: ids, x: Double(at.x), y: Double(at.y), window: window,
                                                                  folders: folders.isEmpty ? nil : folders)))
            print("files: dropped \(ids.count) at \(at), \(total) bytes")
        }
    }

    /// Each file in parts (kind 34), a folder as one zip (FolderZip, unpacked on the other Mac, the
    /// zip removed here after): their IDs, those of the folders, and the bytes sent. Blocks: call it
    /// off the main thread.
    static func upload(_ urls: [URL], client: StreamClient) -> (ids: [UInt32], folders: [UInt32], total: UInt64) {
        var ids: [UInt32] = []
        var folders: [UInt32] = []
        var total: UInt64 = 0
        for original in urls {
            let isFolder = (try? original.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard let url = isFolder ? FolderZip.zip(original) : original else { continue }
            defer { if isFolder { try? FileManager.default.removeItem(at: url) } }
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init),
                  total + size <= FileChunk.maxTotal else { continue }
            total += size
            let id = UInt32.random(in: 1...UInt32.max)
            if isFolder { folders.append(id) }
            let name = isFolder ? original.lastPathComponent + ".zip" : url.lastPathComponent
            var offset: UInt64 = 0
            repeat {
                let bytes = (try? handle.read(upToCount: FileChunk.maxBytes)) ?? Data()
                client.send(.fileChunk, payload: FileChunk.pack(id: id, name: name, total: size, offset: offset, bytes: bytes))
                offset += UInt64(bytes.count)
                if bytes.isEmpty { break }
            } while offset < size
            try? handle.close()
            ids.append(id)
        }
        return (ids, folders, total)
    }
}

// MARK: Files dragged out of the other Mac's window

extension StreamInputView: NSDraggingSource {
    /// Whether the pointer is over this view's window as it shows, not just within its rectangle:
    /// another window over it (another Sill window, say) counts as leaving it.
    func overOwnWindow() -> Bool {
        guard let window else { return false }
        let at = NSEvent.mouseLocation
        return NSWindow.windowNumber(at: at, belowWindowWithWindowNumber: 0) == window.windowNumber
            && bounds.contains(convert(window.convertPoint(fromScreen: at), from: nil))
    }

    /// The other Mac's drag is let go of there (Esc cancels it, then the button comes up), and the
    /// same files go on being dragged here as promises, fetched from the other Mac when dropped.
    func dragOut(_ offer: DragOffer, event: NSEvent, last: CGPoint) {
        dragOffer = nil
        leftDown = false
        if let live, live.enabled {
            // The other Mac's drag goes on, its button held: over a Sill window the pointer there follows
            // (LiveDrop), and only a drag that ends elsewhere gives it up there.
            live.startOwn(offer: offer.id, window: sourceWindowID, at: last)
        } else {
            forward(.keyDown, keyCode: 53, flags: [], isRepeat: false, via: "drag out")
            forward(.keyUp, keyCode: 53, flags: [], isRepeat: false, via: "drag out")
            send(.leftUp, last)
        }
        let promises = FilePromises.shared
        let items = offer.files.enumerated().map { index, file -> NSDraggingItem in
            let type = file.folder == true ? UTType.folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promises)
            provider.userInfo = FilePromises.Promise(client: client, offer: offer.id, index: index, name: file.name, size: file.size,
                                                     folder: file.folder == true)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let at = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: at.x - 24, y: at.y - 24, width: 48, height: 48),
                                  contents: NSWorkspace.shared.icon(for: file.folder == true ? .folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)))
            return item
        }
        outgoing = items.compactMap { ($0.item as? NSFilePromiseProvider)?.userInfo as? FilePromises.Promise }
        windowLog("files: dragging \(offer.files.map(\.name).joined(separator: ", ")) out of the other Mac")
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Outside: Finder copies, the Dock's Trash deletes. Inside: another Sill window, where the
        // other Mac drops its own files (LiveDrop, or StreamWindows.dropped); none here kept them from it.
        context == .outsideApplication ? [.copy, .delete] : [.copy, .move, .generic]
    }

    /// Dropped on the Trash: the files go to the other Mac's Trash, as dragging them to its own would.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        live?.ownEnded()   // not let go on a Sill window: the other Mac gives its own drag up
        guard operation == .delete else { return }
        for promise in outgoing {
            promise.client.send(.fileRequest, payload: Wire.encode(FileRequest(offer: promise.offer, index: promise.index, transfer: 0, trash: true)))
        }
        print("files: \(outgoing.count) dragged to the Trash: moved to the other Mac's")
        outgoing = []
    }
}

/// The promised files of a drag out (NSFilePromiseProvider): each, when dropped here, is asked for
/// (kind 37) and written from its parts (kind 34) where the drop wants it.
final class FilePromises: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = FilePromises()
    struct Promise { let client: StreamClient; let offer: UInt32; let index: Int; let name: String; let size: UInt64; let folder: Bool }
    /// A file being written from its parts; a folder's zip goes to `zip` and is unpacked at `url`.
    private struct Writing { let handle: FileHandle; var total: UInt64; var written: UInt64; let done: (Error?) -> Void; let url: URL; let zip: URL? }
    private let lock = NSLock()
    private var writing: [UInt32: Writing] = [:]
    private let queue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInitiated; return q }()
    private var hooked = Set<ObjectIdentifier>()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? Promise)?.name ?? "file"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let p = provider.userInfo as? Promise else { completionHandler(CocoaError(.fileWriteUnknown)); return }
        let zip = p.folder ? FileManager.default.temporaryDirectory.appendingPathComponent("sill-\(UUID().uuidString).zip") : nil
        let target = zip ?? url
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: target) else { completionHandler(CocoaError(.fileWriteUnknown)); return }
        hook(p.client)
        let transfer = UInt32.random(in: 1...UInt32.max)
        lock.lock()
        writing[transfer] = Writing(handle: handle, total: p.size, written: 0, done: completionHandler, url: url, zip: zip)
        lock.unlock()
        if p.size == 0, !p.folder { finish(transfer, nil) }
        p.client.send(.fileRequest, payload: Wire.encode(FileRequest(offer: p.offer, index: p.index, transfer: transfer)))
        // The other Mac gone or never answering: the drop fails rather than leaving a file half made.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60 + Double(p.size) / 2_000_000) { [weak self] in
            self?.finish(transfer, CocoaError(.fileReadUnknown))
        }
    }

    private func hook(_ client: StreamClient) {
        lock.lock(); defer { lock.unlock() }
        guard hooked.insert(ObjectIdentifier(client)).inserted else { return }
        client.onFileChunk = { [weak self] data in self?.chunk(data) }
    }

    private func chunk(_ data: Data) {
        guard let c = FileChunk.unpack(data) else { return }
        lock.lock()
        guard var w = writing[c.id], c.offset == w.written else { lock.unlock(); return }
        if c.offset == 0 { w.total = c.total }   // the size as sent: a folder's zip is only known then
        w.handle.write(c.bytes)
        w.written += UInt64(c.bytes.count)
        writing[c.id] = w
        let complete = w.written >= w.total
        lock.unlock()
        if complete { finish(c.id, nil) }
    }

    private func finish(_ transfer: UInt32, _ error: Error?) {
        lock.lock()
        let w = writing.removeValue(forKey: transfer)
        lock.unlock()
        guard let w else { return }
        try? w.handle.close()
        guard let zip = w.zip else { w.done(error); return }
        // A folder: its zip unpacked where the drop asked for it.
        defer { try? FileManager.default.removeItem(at: zip) }
        guard error == nil else { w.done(error); return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil,
              let folder = FolderZip.unzip(zip, into: scratch, name: w.url.lastPathComponent),
              (try? FileManager.default.moveItem(at: folder, to: w.url)) != nil else {
            w.done(CocoaError(.fileWriteUnknown)); return
        }
        w.done(nil)
    }
}

/// A Mac's scroll events as the host takes them: a trackpad's gesture (its phases, then the deltas as
/// fractions of the picture) or a wheel's lines. One per view that scrolls.
struct ScrollState {
    private var scrolling = false
    private var coasting = false
    private var last = CGPoint(x: 0.5, y: 0.5)

    /// The end of a gesture or a coast still under way (where it last was), and nothing after.
    mutating func finish() -> [InputEvent] {
        var out: [InputEvent] = []
        if scrolling { out.append(.scrollGesture(.ended, x: Double(last.x), y: Double(last.y))); scrolling = false }
        if coasting { out.append(.scrollGesture(.momentumEnded, x: Double(last.x), y: Double(last.y))); coasting = false }
        return out
    }

    /// The events for `event` at `p` (a fraction of a picture of `picture`'s size).
    mutating func events(for event: NSEvent, at p: CGPoint, picture: CGSize) -> [InputEvent] {
        guard picture.width > 0, picture.height > 0 else { return [] }
        last = p
        let x = Double(p.x), y = Double(p.y)
        var out: [InputEvent] = []
        // A mouse wheel's lines: about what a line scrolls on the Mac.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let dx = Double(event.scrollingDeltaX * unit / picture.width)
        let dy = Double(event.scrollingDeltaY * unit / picture.height)
        if event.phase.contains(.began) {
            if scrolling { out.append(.scrollGesture(.ended, x: x, y: y)); scrolling = false }
            if coasting { out.append(.scrollGesture(.momentumEnded, x: x, y: y)); coasting = false }
            out.append(.scrollGesture(.began, x: x, y: y))
            scrolling = true
        }
        if event.momentumPhase.contains(.began) {
            if scrolling { out.append(.scrollGesture(.ended, x: x, y: y)); scrolling = false }
            out.append(.scrollGesture(.momentumBegan, x: x, y: y))
            coasting = true
        }
        if dx != 0 || dy != 0 { out.append(.scroll(x: x, y: y, dx: dx, dy: dy)) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled), scrolling {
            out.append(.scrollGesture(.ended, x: x, y: y))
            scrolling = false
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled), coasting {
            out.append(.scrollGesture(.momentumEnded, x: x, y: y))
            coasting = false
        }
        return out
    }
}
