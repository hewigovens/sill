import AppKit
import Carbon.HIToolbox
import StreamProtocol

/// Typing through this Mac's input method (WindowBridge prototype): Japanese, Chinese or Korean is
/// composed here, with this Mac's candidate window, and only the committed text goes to the other
/// Mac, as InputEvent.text (the host types it with CGEventKeyboardSetUnicodeString). Shortcuts and
/// the keys the input method passes back (Return, Delete, the arrows, Esc and Tab when nothing is
/// composed) still go as keys. With a plain keyboard layout nothing changes: every key goes as a key.
/// Which way each key goes is `TextInputRouter`'s rule (TextInputRouting.swift).
///
/// The other Mac's caret is not known here, so the composition is drawn where the last click on
/// the picture landed (where the caret usually is), and the candidate window opens under it.
/// `WindowBridge.textInput` in the defaults: `auto` (the input method's keys only, the default),
/// `always` (all typing as text, for a keyboard layout the two Macs don't share) or `never` (every
/// key as a key, the viewer as it was).
final class TextInputBridge {
    var router = TextInputRouter()
    var composition = Composition()
    /// The key event being handed to the input method now: what `doCommand(by:)` passes back.
    var current: NSEvent?
    /// Where the composition is drawn, in the view's (flipped) coordinates: the last click.
    var anchor: CGPoint?
    let overlay = CompositionView()

    enum Mode: String { case auto, always, never }
    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "WindowBridge.textInput") ?? "") ?? .auto
    }

    /// Whether the current input source composes (an input method's mode, not a plain layout), by
    /// Text Input Sources: a keyboard input mode or input method that is not ASCII-capable
    /// (Hiragana, Pinyin, 2-Set Korean); Japanese's own alphanumeric mode is ASCII-capable and types
    /// as keys.
    static func inputSourceComposes() -> Bool {
        switch mode {
        case .always: return true
        case .never: return false
        case .auto: break
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        func property(_ key: CFString) -> AnyObject? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }
        let type = property(kTISPropertyInputSourceType) as? String
        let asciiCapable = (property(kTISPropertyInputSourceIsASCIICapable) as? NSNumber)?.boolValue ?? true
        return type != (kTISTypeKeyboardLayout as String) && !asciiCapable
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> TextInputRouter.Modifiers {
        var m: TextInputRouter.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }
}

/// The marked text over the picture: the clause being converted underlined thick, the rest thin.
final class CompositionView: NSView {
    var text = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selected = NSRange(location: 0, length: 0) { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 15)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go through to the picture

    func fittingFrame(at point: CGPoint, in bounds: CGRect) -> CGRect {
        let size = (text as NSString).size(withAttributes: [.font: Self.font])
        let w = ceil(size.width) + 12, h = ceil(size.height) + 8
        let x = min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX - w))
        let y = min(max(point.y - h / 2, bounds.minY), max(bounds.minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let length = (text as NSString).length
        if selected.length > 0, NSMaxRange(selected) <= length {
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: selected)
        }
        s.draw(at: NSPoint(x: 6, y: 4))
    }
}

extension StreamInputView {
    /// The local monitor's question for each key event: true when the event has been dealt with
    /// here (sent as a key, handed to the input method, or swallowed), false to forward it as
    /// before. flagsChanged always goes as before (modifier keys are keys on the other Mac too).
    func routeThroughTextInput(_ event: NSEvent) -> Bool {
        guard TextInputBridge.mode != .never, event.type == .keyDown || event.type == .keyUp else { return false }
        let bridge = textInput
        if event.type == .keyUp {
            switch bridge.router.keyUp(event.keyCode) {
            case .swallow: return true
            default: return false   // its down went as a key: so does its up
            }
        }
        let route = bridge.router.keyDown(event.keyCode, modifiers: TextInputBridge.modifiers(event.modifierFlags),
                                          inputMethod: TextInputBridge.inputSourceComposes(),
                                          composing: bridge.composition.isComposing)
        switch route {
        case .key:
            return false
        case .commitThenKey:
            commitComposition()
            return false
        case .swallow:
            return true
        case .inputMethod:
            bridge.current = event
            defer { bridge.current = nil }
            let handled = inputContext?.handleEvent(event) ?? false
            // Not taken at all (no input context): it goes as a key after all.
            if !handled, bridge.router.passedThrough(event.keyCode) {
                forward(.keyDown, keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat, via: "text input")
            }
            return true
        }
    }

    /// What is being composed goes as text now (a click elsewhere, a shortcut), and the input method
    /// is told to forget it.
    func commitComposition() {
        guard textInput.composition.isComposing else { return }
        if let text = textInput.composition.commitMarked() { sendText(text) }
        inputContext?.discardMarkedText()
        layoutComposition()
    }

    /// The keyboard went elsewhere: the composition is dropped, nothing sent.
    func resetTextInput() {
        textInput.router.reset()
        if textInput.composition.isComposing {
            textInput.composition.clear()
            inputContext?.discardMarkedText()
        }
        layoutComposition()
    }

    func noteClick(at point: CGPoint) {
        textInput.anchor = point
    }

    private func sendText(_ text: String) {
        windowLog("text input: committed \(text.count) character\(text.count == 1 ? "" : "s")")
        emit(.text(text))
    }

    func layoutComposition() {
        let overlay = textInput.overlay
        guard textInput.composition.isComposing else { overlay.removeFromSuperview(); return }
        if overlay.superview !== self { addSubview(overlay) }
        overlay.text = textInput.composition.marked
        overlay.selected = textInput.composition.selected
        let rect = display.videoRect
        let at = textInput.anchor ?? CGPoint(x: rect.minX + 12, y: rect.maxY - 40)
        overlay.frame = overlay.fittingFrame(at: at, in: rect.isEmpty ? bounds : rect)
    }

    private static func string(_ value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }
}

extension StreamInputView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = textInput.composition.commit(Self.string(string)) { sendText(text) }
        layoutComposition()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInput.composition.mark(Self.string(string), selected: selectedRange)
        layoutComposition()
    }

    func unmarkText() {
        if let text = textInput.composition.commitMarked() { sendText(text) }
        layoutComposition()
    }

    func selectedRange() -> NSRange {
        textInput.composition.isComposing ? textInput.composition.selected : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange { textInput.composition.markedRange }

    func hasMarkedText() -> Bool { textInput.composition.isComposing }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let marked = textInput.composition.marked as NSString
        guard marked.length > 0, range.location != NSNotFound, range.location < marked.length else { return nil }
        let clamped = NSRange(location: range.location, length: min(range.length, marked.length - range.location))
        actualRange?.pointee = clamped
        return NSAttributedString(string: marked.substring(with: clamped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .markedClauseSegment] }

    /// Where the candidate window goes: under the composition, in screen coordinates.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local: CGRect
        if textInput.overlay.superview === self {
            local = textInput.overlay.frame
        } else {
            let at = textInput.anchor ?? CGPoint(x: display.videoRect.minX + 12, y: display.videoRect.maxY - 40)
            local = CGRect(x: at.x, y: at.y - 10, width: 1, height: 20)
        }
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The input method did not use the key (nothing composed and Return, Delete, an arrow…): the key
    /// goes to the other Mac as it was pressed.
    override func doCommand(by selector: Selector) {
        guard let event = textInput.current, textInput.router.passedThrough(event.keyCode) else { return }
        forward(.keyDown, keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat, via: "text input")
    }

}
