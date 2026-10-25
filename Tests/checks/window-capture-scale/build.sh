#!/bin/bash
# usage: build.sh WT OUT [WindowCaptureScale.swift override]
# Compiles the window capture's scale (Sources/SillHost/WindowCaptureScale.swift, CoreGraphics only)
# with this check's main.swift. No ScreenCaptureKit, no window, no display.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "${3:-$WT/Sources/SillHost/WindowCaptureScale.swift}" "$T/WindowCaptureScale.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
