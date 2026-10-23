import Foundation

var checks = 0, failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
typealias R = TextInputRouter
let none: R.Modifiers = [], cmd: R.Modifiers = [.command], ctrl: R.Modifiers = [.control], shift: R.Modifiers = [.shift]
let kA: UInt16 = 0, kS: UInt16 = 1, kReturn: UInt16 = 36, kSpace: UInt16 = 49, kC: UInt16 = 8, kEisu: UInt16 = 102, kKana: UInt16 = 104

// A plain layout, nothing composed: every key is a key, its up too (the viewer as before).
do {
    var r = R()
    for k: UInt16 in [kA, kS, kReturn, kSpace] {
        check(r.keyDown(k, modifiers: none, inputMethod: false, composing: false) == .key, "layout: \(k) down is a key")
        check(r.keyUp(k) == .key, "layout: \(k) up is a key")
    }
    check(r.keyDown(kA, modifiers: shift, inputMethod: false, composing: false) == .key, "layout: ⇧A is a key")
    check(r.keyDown(kS, modifiers: cmd, inputMethod: false, composing: false) == .key, "layout: ⌘S is a key")
    check(r.keyDown(kC, modifiers: ctrl, inputMethod: false, composing: false) == .key, "layout: ⌃C is a key")
}

// An input method: letters go to it, and their ups are swallowed.
do {
    var r = R()
    check(r.keyDown(kA, modifiers: none, inputMethod: true, composing: false) == .inputMethod, "IME: a goes to the input method")
    check(r.keyUp(kA) == .swallow, "IME: a's up is swallowed")
    check(r.keyDown(kA, modifiers: shift, inputMethod: true, composing: true) == .inputMethod, "IME: ⇧A mid-composition goes to it")
    check(r.keyUp(kA) == .swallow, "IME: ⇧A's up is swallowed")
    check(r.keyDown(kSpace, modifiers: none, inputMethod: true, composing: true) == .inputMethod, "IME: Space converts")
    check(r.keyDown(kReturn, modifiers: none, inputMethod: true, composing: true) == .inputMethod, "IME: Return commits")
}

// Shortcuts: ⌘ always a key, committing a composition first; ⌃ a key only while nothing is composed.
do {
    var r = R()
    check(r.keyDown(kS, modifiers: cmd, inputMethod: true, composing: false) == .key, "IME: ⌘S is a key")
    check(r.keyUp(kS) == .key, "IME: ⌘S's up is a key")
    check(r.keyDown(kS, modifiers: cmd, inputMethod: true, composing: true) == .commitThenKey, "IME: ⌘S mid-composition commits first")
    check(r.keyUp(kS) == .key, "IME: its up is a key")
    check(r.keyDown(kC, modifiers: ctrl, inputMethod: true, composing: false) == .key, "IME: ⌃C with nothing composed is a key")
    check(r.keyDown(kC, modifiers: ctrl, inputMethod: true, composing: true) == .inputMethod, "IME: ⌃C mid-composition is the input method's")
    check(r.keyUp(kC) == .swallow, "IME: and its up is swallowed")
    check(r.keyDown(kS, modifiers: [.command, .shift], inputMethod: false, composing: true) == .commitThenKey,
          "a layout with leftover marked text: ⇧⌘S commits first")
    check(r.keyDown(kA, modifiers: none, inputMethod: false, composing: true) == .inputMethod,
          "switched to a layout mid-composition: keys stay with the input method until it commits")
}

// Eisu and Kana switch the input method here, whatever the source, and never go as keys.
do {
    var r = R()
    for k in [kEisu, kKana] {
        check(r.keyDown(k, modifiers: none, inputMethod: false, composing: false) == .inputMethod, "\(k) goes to the input method")
        check(!r.passedThrough(k), "\(k) is never passed through as a key")
        check(r.keyUp(k) == .swallow, "\(k)'s up is swallowed")
        check(r.keyDown(k, modifiers: cmd, inputMethod: true, composing: false) == .inputMethod, "⌘\(k) too")
        _ = r.keyUp(k)
    }
}

// What the input method passes back goes as a key, down now and up later.
do {
    var r = R()
    check(r.keyDown(kReturn, modifiers: none, inputMethod: true, composing: false) == .inputMethod, "Return goes to the input method")
    check(r.passedThrough(kReturn), "passed back: its down goes now")
    check(!r.passedThrough(kReturn), "passed back once only")
    check(r.keyUp(kReturn) == .key, "and its up goes as a key")
    check(r.keyUp(kReturn) == .swallow, "a second up is swallowed")
    check(!r.passedThrough(kA), "a key the input method was not handed is never passed through")
}

// An up with no down seen (pressed before the view had the keyboard) goes nowhere.
do {
    var r = R()
    check(r.keyUp(kA) == .swallow, "an up with no down is swallowed")
}

// The same key's down changing route mid-hold: the up follows the last down.
do {
    var r = R()
    _ = r.keyDown(kA, modifiers: none, inputMethod: true, composing: false)
    check(r.keyDown(kA, modifiers: cmd, inputMethod: true, composing: false) == .key, "⌘ added while A repeats: a key")
    check(!r.passedThrough(kA), "a key re-routed to the Mac is no longer the input method's to pass back")
    check(r.keyUp(kA) == .key, "A's up then goes as a key")
    _ = r.keyDown(kA, modifiers: cmd, inputMethod: true, composing: false)
    check(r.keyDown(kA, modifiers: none, inputMethod: true, composing: false) == .inputMethod, "⌘ let go: the input method's again")
    check(r.keyUp(kA) == .swallow, "and the up is swallowed")
}

// reset() forgets every key.
do {
    var r = R()
    _ = r.keyDown(kA, modifiers: none, inputMethod: false, composing: false)
    _ = r.keyDown(kS, modifiers: none, inputMethod: true, composing: false)
    r.reset()
    check(r.keysDown.isEmpty && r.methodDown.isEmpty, "reset forgets every key")
    check(r.keyUp(kA) == .swallow, "after reset an up goes nowhere")
}

// A random session: every up that goes as a key follows a down that went as a key, and none twice.
do {
    var r = R()
    var sentDown = Set<UInt16>()
    var rng = SystemRandomNumberGenerator()
    var violations = 0
    for _ in 0..<50_000 {
        let k = UInt16.random(in: 0...12, using: &rng) == 12 ? kEisu : UInt16.random(in: 0...11, using: &rng)
        let mods = R.Modifiers(rawValue: Int.random(in: 0...15, using: &rng))
        switch Int.random(in: 0...3, using: &rng) {
        case 0, 1:
            let route = r.keyDown(k, modifiers: mods, inputMethod: Bool.random(using: &rng), composing: Bool.random(using: &rng))
            if route == .key || route == .commitThenKey { sentDown.insert(k) } else { sentDown.remove(k) }
        case 2:
            if r.passedThrough(k) { sentDown.insert(k) }
        default:
            let route = r.keyUp(k)
            if route == .key { if sentDown.remove(k) == nil { violations += 1 } }
            else if sentDown.contains(k) { violations += 1 }   // a key the Mac holds must get its up
        }
    }
    check(violations == 0, "random session: \(violations) ups that do not match what went down")
}

// The composition.
do {
    var c = Composition()
    check(!c.isComposing && c.markedRange.location == NSNotFound, "starts empty")
    c.mark("か", selected: NSRange(location: 1, length: 0))
    check(c.isComposing && c.marked == "か" && c.markedRange == NSRange(location: 0, length: 1), "marked か")
    c.mark("かんじ", selected: NSRange(location: 3, length: 0))
    c.mark("漢字", selected: NSRange(location: 0, length: 2))
    check(c.selected == NSRange(location: 0, length: 2), "the clause being converted is selected")
    check(c.commit("漢字") == "漢字" && !c.isComposing, "insertText commits and ends it")
    check(c.commit("") == nil, "an empty commit sends nothing")
    c.mark("にほん", selected: NSRange(location: NSNotFound, length: 0))
    check(c.selected == NSRange(location: 3, length: 0), "a selection of NSNotFound is the end")
    c.mark("にほん", selected: NSRange(location: 9, length: 4))
    check(c.selected == NSRange(location: 3, length: 0), "a selection past the end is clamped")
    c.mark("にほん", selected: NSRange(location: 1, length: 9))
    check(c.selected == NSRange(location: 1, length: 2), "a selection's length is clamped")
    check(c.commitMarked() == "にほん" && !c.isComposing, "unmarkText commits the marked text")
    c.mark("😀a", selected: NSRange(location: 3, length: 0))
    check(c.markedRange.length == 3, "lengths are UTF-16 units")
    check(c.selected == NSRange(location: 3, length: 0), "the selection is in UTF-16 units too")
    c.mark("", selected: NSRange(location: 0, length: 0))
    check(!c.isComposing && c.commitMarked() == nil, "empty marked text ends the composition with nothing")
}

print("text-input: \(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
