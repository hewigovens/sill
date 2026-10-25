"""Mutants of WindowCaptureScale.swift: each changes it in one place, is compiled with the check by
build.sh and must make it fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]; HERE = os.path.dirname(os.path.abspath(__file__))
F = os.path.join(WT, "Sources/SillHost/WindowCaptureScale.swift")
MUTANTS = [
    ("the stream's scale whatever the window's (before the fix)", "return min(captureScale, CGFloat(windowScale))", "return captureScale"),
    ("the window's scale whatever the stream's", "return min(captureScale, CGFloat(windowScale))", "return CGFloat(windowScale)"),
    ("the larger of the two", "return min(captureScale, CGFloat(windowScale))", "return max(captureScale, CGFloat(windowScale))"),
    ("a scale of 0 taken", "guard windowScale > 0 else", "guard windowScale >= 0 else"),
    ("an unknown scale read as 1", "else { return captureScale }", "else { return 1 }"),
    ("an unknown scale read as the window's", "else { return captureScale }", "else { return CGFloat(windowScale) }"),
]
caught = 0
for name, old, new in MUTANTS:
    src = open(F).read()
    if src.count(old) != 1:
        print(f"{name}: NOT APPLIED (pattern found {src.count(old)} times)"); continue
    with tempfile.TemporaryDirectory() as t:
        mf = os.path.join(t, "WindowCaptureScale.swift"); open(mf, "w").write(src.replace(old, new, 1))
        exe = os.path.join(t, "c")
        subprocess.run([os.path.join(HERE, "build.sh"), WT, exe, mf], capture_output=True, text=True)
        if not os.path.exists(exe): print(f"{name}: did not compile"); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=60)
        failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        if r.returncode != 0:
            caught += 1
            print(f"{name}: caught ({failed[0][:90] if failed else f'exit status {r.returncode}'})")
        else:
            print(f"{name}: NOT CAUGHT")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
