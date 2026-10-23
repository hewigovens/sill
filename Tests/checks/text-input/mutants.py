#!/usr/bin/env python3
"""One-line mutants of Sources/MacClient/TextInputRouting.swift; each must make the check fail."""
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1]); src = root / "Sources/MacClient/TextInputRouting.swift"
here = pathlib.Path(__file__).parent; out = root / ".build/checks/text-input"; out.mkdir(parents=True, exist_ok=True)
MUTANTS = [
    ("if modifiers.contains(.command) { return toKey(keyCode, commit: composing) }", "if modifiers.contains(.command) { return toKey(keyCode, commit: false) }"),
    ("if modifiers.contains(.command) { return toKey(keyCode, commit: composing) }", ""),
    ("if !inputMethod && !composing { return toKey(keyCode, commit: false) }", "if !inputMethod { return toKey(keyCode, commit: false) }"),
    ("if modifiers.contains(.control) && !composing {", "if modifiers.contains(.control) {"),
    ("if Self.inputModeKeys.contains(keyCode) { return toMethod(keyCode) }", ""),
    ("guard methodDown.remove(keyCode) != nil, !Self.inputModeKeys.contains(keyCode) else { return false }", "guard !Self.inputModeKeys.contains(keyCode) else { return false }"),
    ("        keysDown.insert(keyCode)\n        return true", "        return true"),
    ("if keysDown.remove(keyCode) != nil { return .key }", "if keysDown.contains(keyCode) { return .key }"),
    ("        methodDown.remove(keyCode)\n        keysDown.insert(keyCode)\n        return commit", "        keysDown.insert(keyCode)\n        return commit"),
    ("        keysDown.remove(keyCode)\n        methodDown.insert(keyCode)", "        methodDown.insert(keyCode)"),
    ("        keysDown.removeAll()\n        methodDown.removeAll()", "        methodDown.removeAll()"),
    ("let location = min(max(range.location == NSNotFound ? length : range.location, 0), length)", "let location = min(max(range.location == NSNotFound ? 0 : range.location, 0), length)"),
    ("selected = NSRange(location: location, length: min(max(range.length, 0), length - location))", "selected = NSRange(location: location, length: range.length)"),
    ("return text.isEmpty ? nil : text", "return text"),
    ("let length = (text as NSString).length", "let length = text.count"),
]
caught = 0
original = src.read_text()
try:
    for i, (old, new) in enumerate(MUTANTS, 1):
        assert original.count(old) == 1, f"mutant {i}: pattern not found once"
        src.write_text(original.replace(old, new))
        b = subprocess.run(["swiftc", "-O", str(src), str(here / "main.swift"), "-o", str(out / "mutant")], capture_output=True, text=True)
        if b.returncode != 0:
            print(f"mutant {i}: does not compile (caught)"); caught += 1; continue
        r = subprocess.run([str(out / "mutant")], capture_output=True, text=True)
        ok = r.returncode != 0
        caught += ok
        print(f"mutant {i}: {'caught' if ok else 'SURVIVED'}")
finally:
    src.write_text(original)
print(f"{caught} of {len(MUTANTS)} mutants caught")
