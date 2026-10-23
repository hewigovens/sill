#!/bin/bash
# The Mac client's text input rule (Sources/MacClient/TextInputRouting.swift, WindowBridge
# prototype): which keys go to the other Mac as keys and which to this Mac's input method, a key's
# up going the way its down went, and the composition's marked text and commits.
#   Tests/checks/text-input/run.sh             compile and run the check
#   Tests/checks/text-input/run.sh --mutants   one-line mutants of TextInputRouting.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
swiftc -O Sources/MacClient/TextInputRouting.swift "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
