import CoreGraphics

/// The scale a window captured where it is is encoded at: the stream's (`captureScale`: 2 for
/// Retina, 1 for Standard), but never more than the window's own (`SCContentFilter.pointPixelScale`:
/// 1 on a non-Retina display, and on a Mac with no display once a Screen Sharing session has ended).
/// ScreenCaptureKit, without `scalesToFit`, draws a window smaller than its output into the output's
/// top-left corner instead of scaling it up, so a 1× window captured at 2× filled a quarter of the
/// picture and left the rest black. A scale the filter does not give (0, or not a number) leaves the
/// stream's. Pure: Tests/checks/window-capture-scale.
func windowCaptureScale(_ captureScale: CGFloat, windowScale: Float) -> CGFloat {
    guard windowScale > 0 else { return captureScale }   // NaN is not > 0; infinity leaves the stream's
    return min(captureScale, CGFloat(windowScale))
}
