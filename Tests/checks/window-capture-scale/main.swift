import CoreGraphics
import Foundation

// Checks windowCaptureScale (Sources/SillHost/WindowCaptureScale.swift): the scale a window
// captured where it is is encoded at. Compiled alone with swiftc (CoreGraphics only), build.sh:
//   swiftc -O Sources/SillHost/WindowCaptureScale.swift Tests/checks/window-capture-scale/main.swift
// First the cases a Mac meets, then every stream scale against a grid of window scales.

var checks = 0, failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL line \(line): \(what())") }
}
func same(_ got: CGFloat, _ want: CGFloat, _ what: String, line: Int = #line) {
    check(got == want, "\(what): got \(got), want \(want)", line: line)
}

let retina: CGFloat = 2, standard: CGFloat = 1

// A Retina window at Retina: as before.
same(windowCaptureScale(retina, windowScale: 2), 2, "a Retina window at Retina")
// A 1× window at Retina (a non-Retina display, or a Mac with no display after Screen Sharing ends):
// its own pixels, where it was captured at 2× and filled the output's top-left quarter.
same(windowCaptureScale(retina, windowScale: 1), 1, "a 1× window at Retina")
// The window from the report: 1920 × 964 points at scale 1 goes out 1920 × 964, not 3840 × 1928.
let reported = CGSize(width: 1920, height: 964)
let s = windowCaptureScale(retina, windowScale: 1)
check(Int(reported.width * s) == 1920 && Int(reported.height * s) == 964,
      "the reported window's picture: got \(Int(reported.width * s)) × \(Int(reported.height * s))")
// Standard: a Retina window shrinks to points as before, and a 1× window stays at points.
same(windowCaptureScale(standard, windowScale: 2), 1, "a Retina window at Standard")
same(windowCaptureScale(standard, windowScale: 1), 1, "a 1× window at Standard")
// The software encoder's half scale (captureScale at most 1).
same(windowCaptureScale(min(retina, 1), windowScale: 2), 1, "the software encoder with a Retina window")
// Never above the stream's, whatever the window's.
same(windowCaptureScale(retina, windowScale: 3), 2, "a 3× window at Retina")
same(windowCaptureScale(retina, windowScale: 1.5), 1.5, "a 1.5× window at Retina")
same(windowCaptureScale(standard, windowScale: 1.5), 1, "a 1.5× window at Standard")
// A scale the filter does not give leaves the stream's.
for unknown: Float in [0, -1, -.infinity, .nan] {
    same(windowCaptureScale(retina, windowScale: unknown), 2, "Retina with the window's scale \(unknown)")
    same(windowCaptureScale(standard, windowScale: unknown), 1, "Standard with the window's scale \(unknown)")
}
same(windowCaptureScale(retina, windowScale: .infinity), 2, "Retina with an infinite window scale")

// Every stream scale against a grid of window scales: never more than the stream's, never more than
// a window's given scale, and one of the two.
for stream in stride(from: CGFloat(0.5), through: 3, by: 0.25) {
    for w in stride(from: Float(0.25), through: 4, by: 0.125) {
        let got = windowCaptureScale(stream, windowScale: w)
        check(got <= stream, "stream \(stream), window \(w): \(got) is above the stream's")
        check(got <= CGFloat(w), "stream \(stream), window \(w): \(got) is above the window's")
        check(got == stream || got == CGFloat(w), "stream \(stream), window \(w): \(got) is neither")
    }
}

print("window-capture-scale: \(checks - failures) of \(checks) checks passed")
exit(failures == 0 ? 0 : 1)
