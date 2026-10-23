import Foundation

/// Which way each of this Mac's keys goes when an input method is in use (WindowBridge prototype):
/// to the other Mac as a key (InputEvent.key, its HID usage and modifiers), or to this Mac's input
/// method, which composes locally and hands over committed text (InputEvent.text). Pure: Foundation
/// only, so it is checked on its own with swiftc (Tests/checks/text-input).
///
/// The rule:
/// - With a keyboard layout (ABC, US, a non-composing layout) and nothing being composed, every key
///   goes as a key, as before: the other Mac's layout reads it, key repeat and games work.
/// - With an input method (Japanese, Chinese, Korean…) every key goes to it, except shortcuts: a key
///   with ⌘ goes as a key (a composition under way is committed first), and one with ⌃ goes as a key
///   while nothing is being composed (⌃C in a terminal; input methods take ⌃ only mid-composition).
/// - JIS Eisu and Kana switch the input method here and never reach the other Mac.
/// - What the input method passes back unhandled (`doCommand(by:)`: Return, Delete, the arrows, Tab
///   and Esc while nothing is composed) goes as that key after all (`passedThrough`).
/// - A key's up goes the way its down went: a key whose down went to the input method has its up
///   swallowed, so the other Mac never sees an up without its down.
struct TextInputRouter {
    enum Route: Equatable {
        /// Send the key to the other Mac (InputEvent.key).
        case key
        /// Commit what is being composed (sent as text), then send the key.
        case commitThenKey
        /// Hand the event to this Mac's input method (NSTextInputContext.handleEvent).
        case inputMethod
        /// Nothing goes to the other Mac (the up of a key the input method had).
        case swallow
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    /// JIS keyboards' Eisu (英数) and Kana (かな) keys: kVK_JIS_Eisu, kVK_JIS_Kana.
    static let inputModeKeys: Set<UInt16> = [102, 104]

    /// Keys whose down went to the other Mac, so their up does too.
    private(set) var keysDown: Set<UInt16> = []
    /// Keys whose down went to the input method, so their up is swallowed.
    private(set) var methodDown: Set<UInt16> = []

    /// A key went down. `inputMethod`: the current input source composes (not a plain layout);
    /// `composing`: marked text is showing now.
    mutating func keyDown(_ keyCode: UInt16, modifiers: Modifiers, inputMethod: Bool, composing: Bool) -> Route {
        if Self.inputModeKeys.contains(keyCode) { return toMethod(keyCode) }
        if modifiers.contains(.command) { return toKey(keyCode, commit: composing) }
        if !inputMethod && !composing { return toKey(keyCode, commit: false) }
        if modifiers.contains(.control) && !composing { return toKey(keyCode, commit: false) }
        return toMethod(keyCode)
    }

    /// The input method did not use the key it was handed (doCommand(by:) during its handleEvent):
    /// it goes to the other Mac after all. True when its down should be sent now.
    mutating func passedThrough(_ keyCode: UInt16) -> Bool {
        guard methodDown.remove(keyCode) != nil, !Self.inputModeKeys.contains(keyCode) else { return false }
        keysDown.insert(keyCode)
        return true
    }

    /// A key came up.
    mutating func keyUp(_ keyCode: UInt16) -> Route {
        if keysDown.remove(keyCode) != nil { return .key }
        methodDown.remove(keyCode)
        return .swallow
    }

    /// The view lost the keyboard: what it holds is forgotten (StreamInputView lets its keys go).
    mutating func reset() {
        keysDown.removeAll()
        methodDown.removeAll()
    }

    private mutating func toKey(_ keyCode: UInt16, commit: Bool) -> Route {
        methodDown.remove(keyCode)
        keysDown.insert(keyCode)
        return commit ? .commitThenKey : .key
    }

    private mutating func toMethod(_ keyCode: UInt16) -> Route {
        keysDown.remove(keyCode)
        methodDown.insert(keyCode)
        return .inputMethod
    }
}

/// What the input method is composing here: the marked text and its selection, shown over the
/// picture until it is committed (sent to the other Mac as text) or abandoned. Pure.
struct Composition: Equatable {
    private(set) var marked = ""
    /// The selected part of `marked`, in UTF-16 units, as NSTextInputClient counts.
    private(set) var selected = NSRange(location: 0, length: 0)

    var isComposing: Bool { !marked.isEmpty }

    /// setMarkedText: an empty string ends the composition without text.
    mutating func mark(_ text: String, selected range: NSRange) {
        marked = text
        let length = (text as NSString).length
        let location = min(max(range.location == NSNotFound ? length : range.location, 0), length)
        selected = NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// insertText: the committed text to send, and the composition ends. Empty text sends nothing.
    mutating func commit(_ text: String) -> String? {
        clear()
        return text.isEmpty ? nil : text
    }

    /// unmarkText, or a shortcut mid-composition: the marked text as it stands is committed.
    mutating func commitMarked() -> String? {
        commit(marked)
    }

    mutating func clear() {
        marked = ""
        selected = NSRange(location: 0, length: 0)
    }

    /// markedRange() for NSTextInputClient.
    var markedRange: NSRange {
        isComposing ? NSRange(location: 0, length: (marked as NSString).length) : NSRange(location: NSNotFound, length: 0)
    }
}
