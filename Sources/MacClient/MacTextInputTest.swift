#if DEBUG
import AppKit

/// DEBUG `-SillTextInputTest 1` (WindowBridge prototype): once, a second after the first frame, the
/// text input path end to end against a host's input log (`SILL_TEST_INPUT_LOG=1 SillHost
/// --synthetic`): an input method's calls as Japanese makes them (marked か, かん, 漢字, then
/// committed), a composition cut short by a click, and real key events through this Mac's own
/// NSTextInputContext with `WindowBridge.textInput` at `always` (a, Return, ⌘S). Only to a test host
/// on this Mac's loopback whose window list has no version (never Sill.app). Each step prints
/// "text input test: …"; the host's log should show the committed text and the keys.
enum MacTextInputTest {
    static var done = false

    static func runIfAsked(_ view: StreamInputView) {
        guard UserDefaults.standard.bool(forKey: "SillTextInputTest"), !done else { return }
        done = true
        guard view.client.hostVersion == nil, case .hostPort(let host, _)? = view.client.connection?.endpoint,
              ["127.0.0.1", "::1", "localhost"].contains("\(host)".split(separator: "%").first.map(String.init) ?? "") else {
            print("text input test: refused: only a test host on this Mac's loopback")
            return
        }
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "an input method composes 漢字 and commits it", {
                view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                view.setMarkedText("漢字", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
                print("text input test: marked \(view.markedRange()), overlay shown: \(view.textInput.overlay.superview != nil), candidate rect \(view.firstRect(forCharacterRange: view.markedRange(), actualRange: nil))")
                view.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
                print("text input test: after commit, composing \(view.hasMarkedText()), overlay shown: \(view.textInput.overlay.superview != nil)")
            }),
            (1.5, "a composition cut short by a click is committed", {
                view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                view.commitComposition()
            }),
            (2.0, "real keys through this Mac's input context, all typing as text", {
                UserDefaults.standard.set("always", forKey: "WindowBridge.textInput")
                view.inputContext?.activate()
                for (code, chars, flags) in [(UInt16(0), "a", NSEvent.ModifierFlags()), (36, "\r", []), (1, "s", [.command])] {
                    for down in [true, false] {
                        guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                                       keyCode: code) else { continue }
                        let taken = view.routeThroughTextInput(e)
                        if !taken { view.forward(e.type, keyCode: e.keyCode, flags: e.modifierFlags, isRepeat: false, via: "text input test") }
                        print("text input test: key \(code) \(down ? "down" : "up") \(flags.contains(.command) ? "⌘ " : "")→ \(taken ? "taken by the text input path" : "sent as a key")")
                    }
                }
                UserDefaults.standard.removeObject(forKey: "WindowBridge.textInput")
            }),
        ]
        for (t, what, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                print("text input test: \(what)")
                step()
            }
        }
    }
}
#endif
