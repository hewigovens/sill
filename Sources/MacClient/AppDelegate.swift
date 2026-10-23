import AppKit
import Combine
import SwiftUI
import StreamProtocol

/// The app: one StreamClient (the iPhone and iPad app's session, shared), the other Mac's windows as
/// this Mac's windows (StreamWindows), the controlled app's menus in the menu bar (the Dock icons',
/// DockProxies, or this app's own, MainMenu), and Sill's own controls in a status item (StatusMenu).
/// The connect window shows while no session is up, and from the status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = StreamClient()
    private let reporter = ClientStatsReporter()
    private(set) lazy var windows = StreamWindows(client: client)
    private(set) lazy var mainMenu = MainMenu(client: client)
    private var status: StatusMenu?
    private var clipboardSync: ClipboardSync?
    let audio = AudioPlayer()
    private var connectWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.picksDesktopItself = false   // the user's windows to open; the Desktop once, on connecting
        reporter.attach(to: client)
        mainMenu.install()
        status = StatusMenu(app: self)
        clipboardSync = ClipboardSync(client: client)
        let audio = self.audio
        client.onAudio = { if AudioPlayer.enabled { audio.receive($0) } }
        client.$connected.removeDuplicates().sink { [weak self] connected in
            DispatchQueue.main.async { self?.connectedChanged(connected) }
        }.store(in: &subscriptions)
        #if DEBUG
        // -SillNoBrowse 1 with -SillConnect: no Bonjour browse and no remote dials, so a test run against
        // a loopback host never brings up macOS's Local Network prompt (WindowBridge prototype).
        let browse = !UserDefaults.standard.bool(forKey: "SillNoBrowse")
        #else
        let browse = true
        #endif
        if browse {
            client.startBrowsing()
            client.startRemote()
        }
        #if DEBUG
        client.connectFromLaunchArgument()   // -SillConnect host:port, for the off-Bonjour test hosts
        #endif
        if let last = UserDefaults.standard.string(forKey: Self.lastMacKey), !client.connected, client.reconnectAtLaunch(last) {
            // Back to the Mac it was connected to when it quit, without a window in the way (it may be
            // a launch at login); the connect window only if that has not worked after a while.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectPatience) { [weak self] in
                guard let self, !self.client.connected else { return }
                self.showConnectWindow()
            }
            return
        }
        if !client.connected { showConnectWindow() }
        NSApp.activate()
    }

    /// The saved Mac (its Mac ID) this app was connected to when it last quit, reconnected to at
    /// launch; forgotten by Disconnect, so a Mac left on purpose stays left.
    private static let lastMacKey = "SillClient.lastMac"
    /// How long a launch's reconnect has before the connect window shows (the reconnect itself goes
    /// on, DiscoveryPolicy.redialWindow).
    private static let reconnectPatience: TimeInterval = 15

    func applicationWillTerminate(_ notification: Notification) {
        windows.closeAll()   // keeps the list of open windows for the next session (closeAll does not forget it)
        windows.dock.quitAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The status item stays; clicking the Dock icon with no window open shows what is useful.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { client.connected ? status?.open() : showConnectWindow() }
        return true
    }

    /// sill://pair from Messages or a browser: a confirmation first, in the connect window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { client.handleOpenURL(url) }
        showConnectWindow()
    }

    private func connectedChanged(_ connected: Bool) {
        if connected {
            if let mac = client.session?.macID { UserDefaults.standard.set(mac, forKey: Self.lastMacKey) }
            connectWindow?.orderOut(nil)
            // The session starts empty: the windows open last time with this Mac come back
            // (StreamWindows), and with none the status item's menu opens so one can be picked. From
            // a run-loop timer, never a main-queue block (the modal-loop rule): the menu's tracking
            // loop runs inside whatever opened it, and inside a main-queue block it holds the main
            // queue until the menu closes, so a session that ended meanwhile (the other Mac's Sill
            // quit) was never ended and never reconnected while the menu stayed open.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self, self.client.connected, self.windows.openSources.isEmpty else { return }
                self.status?.open()
            }
            #if DEBUG
            // -SillOpenWindows N: the host's first N windows open unfocused (side streams, nothing
            // resized), once its list has come.
            let n = UserDefaults.standard.integer(forKey: "SillOpenWindows")
            if UserDefaults.standard.bool(forKey: "SillFlipTest") {
                // -SillFlipTest 1: once the windows are back, the focus goes from one open stream
                // window to the next every 3 s, six times, as a person flipping between apps would.
                for i in 0..<6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(i) * 3) { [weak self] in
                        guard let self else { return }
                        let open = self.windows.openSources.sorted { "\($0)" < "\($1)" }
                        guard open.count >= 2 else { FileHandle.standardError.write(Data("flip test: FAIL \(open.count) windows open\n".utf8)); return }
                        self.windows.flipTest(to: open[i % open.count])
                    }
                }
            }
            // -SillOpenDesktop 1: the Desktop window opens by itself (a synthetic host lists no windows),
            // before the status menu would open for a pick (WindowBridge prototype).
            if UserDefaults.standard.bool(forKey: "SillOpenDesktop") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.windows.open(.desktop, focus: false)
                    self?.windows.flipTest(to: .desktop)   // as if it became key, without taking the front
                }
                for t in [4.0, 8.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.windows.debugReport(.desktop) }
                }
            }
            if UserDefaults.standard.bool(forKey: "SillResizeTest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.windows.open(.desktop)
                    MacResizeTest.run()
                }
            }
            if n > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    for w in self.client.windows.prefix(n) { self.windows.open(.window(w.id), focus: false) }
                    print("test: opened \(min(n, self.client.windows.count)) windows unfocused")
                }
            }
            #endif
        } else {
            audio.stop()
            windows.closeAll()
            showConnectWindow()
        }
    }

    func showConnectWindow() {
        if connectWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ConnectView(client: client)))
            window.title = "Connect to a Mac"
            window.setContentSize(NSSize(width: 560, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            connectWindow = window
        }
        connectWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
        windows.letGo()
        client.disconnect()
    }
}
