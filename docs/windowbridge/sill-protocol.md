# Sill wire protocol, as a Mac client sees it

Read from Sill `main` at `4d990e9` (2026-10-23) and from the open Mac-client pull requests
(#66 / #72 / #73, head `b0afa2c`). File references are to `Sources/StreamProtocol/` unless stated.
Everything here is what the code does, not what the docs promise; where the two differ the code wins.

## 1. Framing

One TCP (or TLS-over-TCP) connection per session. Every message, both directions:

```
offset size  field
0      1     kind          UInt8 (StreamMessageKind)
1      8     timestamp     Float64 big-endian, host wall clock, seconds since 1970
9      1     isKeyframe    0/1 (only meaningful on kinds 1 and 31)
10     4     payloadLength UInt32 big-endian
14     n     payload
```

- An unknown kind decodes as `.unknown` (255) and is skipped by length — this is how every later
  feature stays additive.
- Caps (`StreamMessage`): device→host payload ≤ 1 MiB (host closes the connection otherwise); pairing
  message ≤ 4 KiB; host→device frame ≤ 32 MiB; any other host→device message ≤ 4 MiB.
- Payloads are either binary (video, thumbnails, icons, cursor, ping) or JSON via `JSONEncoder` with
  Swift's synthesized `Codable`. Enums with associated values encode as `{"case":{"_0":…,"label":…}}`:

```json
{"pointer":{"_0":"leftDown","x":0.25,"y":0.5}}
{"scroll":{"dx":0,"dy":-0.01,"x":0.5,"y":0.5}}
{"scrollGesture":{"_0":"began","x":0.5,"y":0.5}}
{"text":{"_0":"漢字"}}
{"key":{"down":true,"hidUsage":26,"modifiers":1048576}}
{"window":{"_0":1234}}   {"desktop":{}}   {"none":{}}
```

- Rules for every JSON type (`HostSettings.swift` header): new fields optional, never renamed or
  retyped, strings rather than enums for anything an older peer decodes, kind numbers never reused.

## 2. Message kinds (main)

| Kind | Name | Dir | Payload |
|---:|---|---|---|
| 0 | parameterSets | H→D | binary: `nalLen(1) count(1) {len(2) bytes}…` (HEVC VPS/SPS/PPS) |
| 1 | frame | H→D | one HEVC access unit, 4-byte length-prefixed NALs (hvcC style); `isKeyframe` set on IDR |
| 2 | windowList | H→D | JSON `WindowList` |
| 3 | thumbnail | H→D | `windowID(4 BE) + JPEG` |
| 4 | appIcon | H→D | `len(2 BE) + bundleID + PNG` |
| 5 | appList | H→D | JSON `[AppInfo]` (installed apps) |
| 6 | selectSource | D→H | JSON `StreamSource`: none / window(id) / desktop |
| 7 | launchApp | D→H | JSON `{bundleID}` |
| 8 | input | D→H | JSON `InputEvent` (§5) |
| 9 | viewport | D→H | JSON `Viewport` (§4.3) |
| 10 / 11 | ping / pong | D→H / H→D | 8 bytes (client clock, Float64 BE), echoed unchanged from the network queue |
| 12 | clientStats | D→H | JSON `ClientStats` once a second (median/max frame age and RTT, fps, device name) |
| 13 | tick | H→D | empty, every 30 ms while streaming or for 3 s after input (keeps the client's Wi‑Fi radio awake) |
| 14 | cursorShape | H→D | `hotX hotY w h` (Float32 BE, Mac points) + PNG, whenever the Mac's cursor changes |
| 15 | windowCommand | D→H | JSON `{id, action: close|minimize|fullScreen}` (pressed through AX) |
| 16 | hostSettings | H→D | JSON `HostSettingsState` — quality, scale, fps cap, virtual display, away/link reports |
| 17 | changeSettings | D→H | JSON `HostSettingsChange` + token; answered with a kind 16 to that device |
| 18 | macInfo | H→D | JSON `SignedMacInfo` (Mac ID, name, remote addresses, ECDSA-signed) |
| 19 / 20 | pairRequest / pairResult | D→H / H→D | pairing connection only (§3) |
| 21 | pairingWanted | D→H | empty: "show your code" (home door, unpaired session) |
| 22 | goodbye | H→D | JSON `Goodbye {reason, message?, minimumVersion?, reconnect?}` |
| 23 | hello | D→H | JSON `Hello {appVersion, build, protocol, device}` — first message of every session |
| 24 / 25 / 27 | macMenu / pressMenuItem / fetchMenu | §6 | the streamed app's menu bar |
| 26 | macPointer | H→D | JSON `{x?, y?, inside?, seen?}` — the Mac's pointer while this device isn't driving |
| 28 | gesture | D→H | JSON `{gesture: swipeUp|swipeDown|swipeLeft|swipeRight|pinch|spread, fingers}` → Mac shortcut |
| 32 | clipboard | both | JSON `{text?, image?, stop?}` (§8) |

Free / claimed elsewhere: 29–31 (Mac client side streams, PR #66), 33–42 (PR #66), 43 (audio, PR #94).

## 3. Doors, pairing and the handshake

### 3.1 Doors

- **Home door**: Bonjour `_sill._tcp`, any free port. Sill.app (and `SillHost --pairing`) speaks
  **TLS 1.3 with mutual key pinning**; the CLI without `--pairing` and DEBUG device builds can still
  use plain TCP. TXT record keys: `r` (recognition tag, readable only by paired devices with the
  32-byte recognition key), `p` ("1" pairing required, "0" open, absent = plain door).
  Admits only loopback, this Mac's own networks and peer-to-peer Wi‑Fi (`OriginPolicy`).
- **Remote door** (Remote Access, default port 7455, `SillHost --remote[=PORT]`): TLS 1.3 only, for
  VPN (Tailscale MagicDNS/100.x/fd7a:115c:a1e0::/48) or, with a second switch, the internet. Paired
  keys only; 8 sessions; a remote client silent for 8 s is evicted; byte-budget frame pacing (§7.3).
- **TLS** (`RemoteTLS`): self-signed P-256 certificates both ways; trust = SHA-256 of the peer's SPKI,
  checked in the verify block without chain evaluation; tickets/resumption off; SNI always `sill`.
  ALPN `sill/1` = session, `sill-pair/1` = pairing (exactly one kind 19 and one kind 20, then close).
  Both are offered by every host for good (the compatibility floor).
- TCP: no Nagle, `serviceClass = .interactiveVideo`; remote door also keepalive 5 s/2 s/3 and a
  15 s unacked drop. Peer-to-peer (AWDL) only with Direct Wireless on.

### 3.2 Pairing (once per device key)

- Device key: P-256 in the keychain (`DeviceIdentity`). Mac key: P-256 identity ("Sill Remote Access").
- Window on the Mac (opened from its menu, or by the device's `ask`): a QR `sill://pair?…` link carrying
  the Mac's fingerprint and a 16-byte secret, and a 12-digit code (11 random digits + Damm check
  digit), 5 minutes, single use, 5 wrong tries.
- Proofs bind both TLS fingerprints, so a relay can't pair:
  `key = secret` (QR) or `PBKDF2-HMAC-SHA256(code, "sill-pair-v1"‖fp_mac, 600 000, 32)` (typed);
  `proof_D = HMAC(key, "sill-pair-v1 device"‖0x00‖fp_dev‖fp_mac)`, `proof_M` symmetric.
- Kind 19 `{v:1, method: qr|code|ask|cancel, proof, name, model?, cable?}` → kind 20
  `{ok, proof, macID, name, recognitionKey}` or `{ok:false, reason: code|closed|expired|stopped|busy|shown|openOnMac|locked, …}`.
  Over the USB cable an `ask` with `cable:true` is paired without a code.
- One trust list serves home and remote doors. Require pairing can be switched off (any device at home,
  still TLS).

### 3.3 Session start (what actually goes over the wire)

```
D: TCP/TLS connect, ALPN sill/1, pinned both ways
D→H 23 hello {appVersion, build, protocol:1, device}            first, always
H   device gate (floor "0" today: everyone admitted); register; ticks start
H→D 2  windowList        (catalog first, so UI can draw before video)
H→D 16 hostSettings
H→D 18 macInfo           (host with an identity only)
H→D 4  appIcon × n, 5 appList, 14 cursorShape
H   encoder.requestKeyframe()
D (on the first windowList; for TLS sessions this is "connected"):
D→H 27 fetchMenu {}      (menu subscription, top level)
D→H 32 clipboard {}      (only if windowList.clipboard ≥ 1 and the device's switch is on)
D→H 9  viewport {width,height,scale?,fps}
D→H 6  selectSource desktop   (only if windowList.active == none; at most every 10 s)
H→D 0  parameterSets, 1 keyframe, 1 deltas…  (+ 2 windowList whenever the active source changes)
D→H 10 ping every 0.25 s, 12 clientStats every 1 s
```

A device that sends anything but a hello first is refused once the floor rises above "0" (kind 22
`update`, `reconnect:false`). Goodbye reasons: `removed`, `remoteOff`, `internetOff`, `quit`, `busy`,
`pairingRequired`, `update`, or any new reason with a `message`.

## 4. Windows

### 4.1 Listing

`WindowList {macName, windows:[WindowInfo], active, launchID?, hostVersion?, protocol?, gestures?, clipboard?}`,
`WindowInfo {id: CGWindowID, title, appName, bundleID, width, height}` — **points, no position, no
scale, no layer, no parent/owner**. Sent at connect and whenever the list or `active` changes; the
catalog polls `SCShareableContent` every 2 s while any client is connected (`WindowCatalog.pollInterval`),
keeping first-seen order. Filter: layer 0, both sides > 100 pt, owner has a name, not Sill itself,
not system helper windows. So **menus, popovers, context menus, tooltips, panels above layer 0 and
small windows are never listed.** There is no explicit "created"/"destroyed" event: a device diffs
successive lists. Thumbnails (kind 3) every 1–2 s per window (6 s when static).

### 4.2 Selecting

Kind 6 `StreamSource`. **The host streams exactly one source at a time, and every connected device
gets the same stream.** A pick in regular mode activates the app and raises + keys the window on the
Mac (AX); capture restarts (new SCStream + encoder). Picks during a restart are queued (newest wins);
picks during a switch to another source are dropped. `launchApp` opens an app (not activated) and
picks its first window.

### 4.3 Resize (Viewport, kind 9)

`Viewport {width, height, scale?, localCursor?, fps?}`: the device's panel in device points and the
"Aa" scale (device points per Mac point). `scale == nil` means *never resize the Mac window*.
With a scale, the host sets the streamed window to `round(panel / scale)` Mac points through
`AXUIElementSetAttributeValue(kAXSizeAttribute)` (`WindowSizer.resize`, with a position nudge so
the window stays on screen), reads back what the app accepted (minimum sizes, aspect locks win),
and the catalog's size check restarts the pipeline at the new size. The window is put back to its
own frame when it stops streaming (`WindowRestore`). The window's **position is never sent and never
set** by the protocol (except the virtual-display staging below). `fps` is the device's wanted rate;
the stream runs at the max over devices, capped by `maxFPS` (120) and 60 on the software encoder; a
change of rate restarts the pipeline.

### 4.4 Virtual display (optional, private API)

With Virtual Display on (`--virtual-display`, or the setting under Sill.app's AppKit loop), a picked
window is moved by AX onto a `CGVirtualDisplay` ("Sill", 2×, square envelope of the panel), and the
display is captured cropped (`sourceRect`) to the window **with the app's other windows included**,
so the app's menus, popovers and sheets appear inside the video. The window never freezes when
covered on the real desktop. Restored on deselect / quit / signals.

## 5. Input (kind 8)

`InputEvent` (Input.swift):

| case | fields | host action (`InputInjector`) |
|---|---|---|
| `pointer` | action ∈ move, leftDown, leftUp, rightDown, rightUp; x, y ∈ [0,1] of the video frame | `CGEvent` mouse event at `rect.origin + (x,y)·rect.size`, click count computed on the host; posted at `.cghidEventTap` (global, not pid-targeted) |
| `scroll` | x, y, dx, dy (fractions of the frame, natural sign) | pixel scroll-wheel event with `scrollWheelEventPointDeltaAxis1/2`; sub-point remainders carried |
| `scrollGesture` | phase ∈ began, ended, momentumBegan, momentumEnded; x, y | stamps `scrollPhase` (began/changed/ended) and `momentumPhase` (begin/continue/end) on the deltas in between; a 2 s (gesture) / 0.5 s (momentum) watchdog closes an open phase |
| `text` | String | per `Character`: `\n` → Return, `\t` → Tab, `\u{8}` → Delete; otherwise a keyDown/keyUp pair on virtual key 0 with `CGEventKeyboardSetUnicodeString`, flags cleared. Held modifier keys of that device are released first |
| `key` | hidUsage (USB HID page 7), down, modifiers (UIKeyModifierFlags = CGEventFlags bits: capsLock 16, shift 17, control 18, option 19, command 20) | `KeyStrokes`: HID usage → macOS virtual keycode (82 keys: letters, digits, punctuation, F1–F12, navigation, modifiers' own keys); flags-changed events for modifier keys; per-device held-key bookkeeping so a key-up leaves only what is still held; released when the device leaves |

So **keys travel as HID keycodes + modifiers (the host's keyboard layout interprets them), and typed
text travels as committed Unicode strings** — the software keyboard path. There is no marked-text /
composition message; an IME has to compose on the device and send the result as `text`.

Pointer events carry no modifiers; ⌘-click = a `key` down for ⌘ (0xE3) then the click. No middle or
other buttons, no pressure, no hover distinct from `move`, no per-window targeting (input lands in
the one streamed source's rectangle).

Before injecting, the host focuses: a left/right down, a key down or text into a window that isn't
frontmost activates its app (`kAXFrontmostAttribute`) and makes the window key (`kAXMainAttribute`
/ raise), then **holds that device's input up to 0.6 s** until the window is on top, so the first
click lands. Scroll only uncovers. Input arriving with nothing streaming is dropped, except the up of
a held key/button.

Kind 28 gestures map to the Mac's own Mission Control / App Exposé / Spaces / Apps / Show Desktop
shortcuts read from its symbolic hotkeys.

## 6. Menus (kinds 24, 25, 27)

- Subscribe: kind 27 with no `id`. Only subscribers are served; the host then sends kind 24 with the
  streamed app's top level (`menus:[{id,title,submenu:true}]`, Apple menu omitted), again whenever
  the app or its top level changes. For the Desktop source: the frontmost app.
- `version` (host-wide) bumps when the app or its top level changes, or when a re-read finds a
  different submenu at a known place. Ids are AX child-index paths from the menu bar ("3.4",
  separators counted, Apple menu = 0) and valid only within one version.
- Fetch: kind 27 `{version, id, title, token}` when a menu opens → kind 24 `{answering, menu, items,
  more?, stale?, note?}`; items `{id, title, separator?, enabled?, mark?, key?, submenu?}`; `key` is
  the shortcut as the Mac draws it ("⇧⌘S", "fn ⌃F") — display only. Reads are on their own AX queue,
  1 s per element, 1.5 s / 500 items per menu, cached 1 s; deadline from the connection's RTT.
- Press: kind 25 `{version, id, title, token}` → kind 24 `{answering, pressed}`. Only a leaf that was
  shown, still has that title, and is enabled is pressed (`AXPress`); a window source's app is
  activated and its window made key first.
- Rates: 20 fetches and 4 presses per second per connection.
- A Mac client's "menu-tree diffing" problem is mostly solved by this design: rebuild a top-level
  `NSMenu` on each kind 24 top level, populate submenus lazily from `menuNeedsUpdate`, and treat any
  version change as invalidating every open submenu.

## 7. Video

### 7.1 Parameters

- One main stream per host (main): capture → encode → broadcast to every registered client.
- Capture: ScreenCaptureKit, `desktopIndependentWindow` filter for a window (regular mode) or the
  display (Desktop; virtual display crop). `420YpCbCr8BiPlanarFullRange`, sRGB, `queueDepth 5`,
  `showsCursor = false` (cursor sent as kind 14), `minimumFrameInterval = 1/fps`. Frames arrive only
  when the window repaints (a still window streams ~0 fps; a covered window freezes in regular mode).
- Size: window points × `captureScale` (2 = "Retina", 1 = "Standard"; the device can change it via
  kind 17). No per-device scale.
- Encoder: VideoToolbox HEVC Main AutoLevel, `RealTime`, `AllowFrameReordering = false` (no B-frames),
  `MaxKeyFrameInterval = fps × 4`, `ExpectedFrameRate = fps`, `AverageBitRate` = preset × fps/60
  (Low 4, Efficient 8, Balanced 15 default, High 25, Pro 40, Ultra 80, Extreme 150 Mbps per 60 fps;
  cap 200), `DataRateLimits [bitrate/8, 1 s]`, optional `PrioritizeEncodingSpeedOverQuality`.
  One frame inside VideoToolbox at a time behind a one-slot mailbox (newer frame replaces the queued
  one), hang watchdog 1.5 s → software encoder at half scale until a re-check passes. Keyframes on
  demand (new client, dropped delta, switch, still window re-encode).
- Software fallback encoder caps at 60 fps.

### 7.2 Timestamps and stats

The header timestamp is the host's wall clock at encode; the device's frame age = its clock − that
(assumes synced clocks). The device reports per-second median/max frame age and ping RTT in kind 12;
the host prints them (`client iPad: 60 fps, frame age 9/24 ms, rtt 7/80 ms`).

### 7.3 Drop policy

- Home clients: a delta is dropped when more than 2 messages are unhanded to the socket (`inflight >
  2`); that client then waits for the next keyframe (parameter sets are re-sent before it).
- Remote clients: byte-budget pacing (`paceRemote`): 256 KiB backlog budget, 128 KiB slack behind the
  last keyframe, 512 KiB hold cap, keyframe re-asks only once ≤ 16 KiB waits, keyframes ≥ 2 s apart.
- Eviction: a home client that drains nothing for 4 s (8 s grace after connect) is dropped.

## 8. Clipboard (kind 32)

Generation 1 (text) when `WindowList.clipboard ≥ 1`. Device sends `{}` to subscribe, `{text}` to set
the Mac's clipboard, `{stop:true}` to unsubscribe. Host polls `NSPasteboard.changeCount` 4×/s while
someone subscribes and sends `{text}` (≤ 256 KiB UTF‑8, JSON ≤ 1 MiB). Concealed/transient/
Universal-Clipboard items and the host's own writes are never sent; writes are `currentHostOnly`.
Images are reserved for generation 2 (`accepts: 2`), implemented in PR #66.

## 9. Cursor and pointer

- Kind 14: the Mac's current system cursor (`NSCursor.currentSystem`) as PNG + hotspot + size in Mac
  points, sent on change and at connect. The video never contains the cursor.
- Kind 26: where the Mac's own pointer is while another party moves it (`inside`, `x`, `y`, `seen` =
  inputs the host had read, so stale reports are dropped).

## 10. Additions in the Mac-client PRs (#66, #72, #73 — not on main)

All additive and gated on new optional `WindowList` fields; the iOS app sends none of them.

| Kind / field | Dir | What |
|---|---|---|
| 8 `middleDown/Up` | D→H | middle button (`WindowList.middleButton`) |
| 8 with `window` | D→H | `WindowInput`: scroll/hover over a background window without raising it |
| 29 `sideStreams` | D→H | `SideStreamRequest {windows, fps (15 default, 30 max), wholeApp, screen, audio, audioCodec, fullRate (≤2), paused, background}` |
| 30 / 31 | H→D | `windowID(4 BE)` + parameter sets / frame for a side window |
| 32 + `accepts:2` | both | clipboard images |
| 33 `audio` | H→D | PCM or AAC-ELD from a CoreAudio process tap (apps muted on the host) |
| 34–38 | both | file drops in, drag out (`NSFilePromiseProvider`), live drags |
| 39 `dockMenu` | both | an app's own Dock menu |
| 40 `pickDisplay` | D→H | which host display the Desktop is; `DesktopWindow` ids have the top bit set |
| 41 `takenBack` | H→D | windows the person at the host took back |
| 42 `rebuildDesk` | D→H | restart the desk's captures |
| `WindowList.badges`, `.attention` | H→D | Dock badges and bounces per app |

Host side: every window a Mac viewer shows lives on **its own hidden `CGVirtualDisplay`** ("Sill's
desk", one per window, distinct vendor/product IDs, sized once to the viewer's largest screen at 2×),
captured as the display cropped to the window with its app's windows (`AppCrop.filter`), so sheets,
popovers and menus show inside the window's picture. Side windows are captured alone.
