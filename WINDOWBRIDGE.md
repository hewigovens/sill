# WindowBridge

A fork of [Sill](https://github.com/Saffsanity/sill) by Noah Saffer, licensed under the Apache
License 2.0 ([LICENSE](LICENSE), unchanged). WindowBridge shows the apps of another Mac (at home, or
through Tailscale) as this Mac's own windows: one window per remote window, with the remote app's
menus in this Mac's menu bar.

Branch `windowbridge-proto` is Sill Viewer, the Mac client from Sill's open pull requests
[#66](https://github.com/Saffsanity/sill/pull/66), #72 and #73 by ashleigh-hopkins, plus WindowBridge's
changes on top. The wire protocol as a Mac client sees it:
[docs/windowbridge/sill-protocol.md](docs/windowbridge/sill-protocol.md).

## Changes from Sill Viewer

Typing through this Mac's input method (Japanese, Chinese, Korean): the text is composed here, with
this Mac's candidate window, and only the committed text goes to the other Mac. No wire or host
change.

- New: `Sources/MacClient/TextInputRouting.swift`, `Sources/MacClient/StreamInputView+TextInput.swift`,
  `Sources/MacClient/MacTextInputTest.swift` (DEBUG), `Tests/checks/text-input/`.
- Changed: `Sources/MacClient/StreamInputView.swift`, `AppDelegate.swift` and `StreamWindows.swift`
  (DEBUG test hooks), and `Sources/SillHost/InputInjector.swift` (the test-only input log prints the
  characters a key carries).
- `defaults write me.saffer.sill.client WindowBridge.textInput auto|always|never` (default `auto`).

## The host, on the Mac whose windows you want

Needs Xcode 27 (27.1 here) as the active developer directory with its license accepted, and an Apple
Development certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates); without
one the app is signed ad hoc and loses Screen Recording and Accessibility at every rebuild.

```
git clone -b windowbridge-proto https://github.com/hewigovens/sill.git windowbridge
cd windowbridge
Scripts/make-app.sh --install --open
```

This replaces `/Applications/Sill.app` (same bundle ID as Sill's download). Grant Screen Recording and
Accessibility when Settings asks, and allow Local Network. Keep Settings › Devices › Require pairing
on. For use away from home, turn on Settings › Remote Access (Tailscale, port 7455).

Devices paired with a downloaded Sill pair again: a build of your own keeps its key in the login
keychain.

**Hidden displays.** For a Mac viewer the host puts each shown window on a hidden virtual display of
its own (a private macOS API), so covered windows keep updating. There is no switch to turn this off
yet. If Sill's menu says "Screen Capture Stopped Working", or the displays misbehave, quit Sill and
log out.

## The viewer, on this Mac

```
Scripts/make-client-app.sh --debug --open
```

Pick the host in Connect to a Mac, and type the code the host shows.
