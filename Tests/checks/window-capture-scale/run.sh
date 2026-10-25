#!/bin/bash
# windowCaptureScale (Sources/SillHost), the scale a window captured where it is is encoded at: the
# stream's, never more than the window's own, so a 1× window at Retina fills the picture instead of
# its top-left quarter. Compiled on its own with swiftc (CoreGraphics only).
#   Tests/checks/window-capture-scale/run.sh             compile and run the check
#   Tests/checks/window-capture-scale/run.sh --mutants   one-line mutants of WindowCaptureScale.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
