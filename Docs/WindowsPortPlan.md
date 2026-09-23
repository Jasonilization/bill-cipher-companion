# Windows Port Plan

Status: **planned, not started.** This document is the working plan for bringing
Bill to Windows; nothing here exists as code yet, and nothing in it has been
tested — it is written so the rewrite can be scoped honestly before a line is
cut. (Wine can't help validate it: Wine runs Windows apps on macOS/Linux, not
the other way around, and there is nothing to run until the port exists. The
first real validation target is a native Windows VM or CI runner.)

## The one-sentence thesis

Keep the *behavior* (state machine, dialogue system, personality, ChatGPT
bridge heuristics) as literal a port as the platforms allow, and re-do the
*presentation* (sprite rendering, windowing, overlays) natively per platform —
because the presentation layer is exactly the part that has no cross-platform
shortcut worth its cost.

## Architecture mapping

| macOS piece | Windows counterpart | Port difficulty | Notes |
|---|---|---|---|
| `NSPanel` + `LSUIElement` (overlay window) | Win32 layered window (`WS_EX_LAYERED \| WS_EX_TRANSPARENT`, per-pixel alpha) | Medium | The well-trodden "desktop pet" window on Windows; the click-through hole-punching must be redone with `SetLayeredWindowAttributes` / `UpdateLayeredWindow` and hit-testing via `WM_NCHITTEST`. |
| SpriteKit scene + 30/12fps throttling | Direct2D composition (or `SkiaSharp` if we want C#-friendly) with a `CompositionTarget`-style render loop | Medium | Bill's sprites are plain PNGs — they port as-is. The 380-sprite catalog, pixel-art `NEAREST` filtering, and frame pacing rules all carry over unchanged. |
| `AnimationClip`/`BillStateMachine`/`AnimationCoverage` | Direct port | **Low** | Pure logic: keyframe tuples, texture sequences, pools. Rewrite in the target language nearly 1:1. This is ~30% of the codebase and ~0% platform. |
| `ReactionRouter` + `DialogueLibrary` + `dialogue.json` | Direct port | **Low** | The JSON dialogue pools and the whole lookup/blend/time-of-day machinery are platform-free by design. |
| WebKit bridge (`ChatBridge`) | **WebView2** (Chromium) | Medium | The injected JS (`ChatGPTBridgeScripts`) is browser-agnostic and ports verbatim; only the host plumbing changes — `CoreWebView2` script injection + `WebMessageReceived` replaces `WKUserContentController` + the relay. The chatgpt.com DOM heuristics are identical since it's the same site in the same engine family. |
| Accessibility window titles (`WindowTitleReader`) | UI Automation (UIA) client API | Medium | Same read-a-title, different IPC. The minimize-button prank maps to UIA `Invoke` on the title-bar's minimize control (`UIA_MinimizeButtonControlTypeId`), which is *more* reliable than the positional AX press. |
| Screen awareness (ScreenCaptureKit + Vision OCR) | Windows.Graphics.Capture + Windows.Media.Ocr | Medium | Both are first-party; capture has a stronger permission story on Windows. |
| `VolumeMonitor` (CoreAudio) | Core Audio APIs / `IAudioEndpointVolume` | Low | Push-driven volume events exist (`IAudioEndpointVolumeCallback`). |
| `WeatherMonitor` (Open-Meteo + geojs) | Direct port | **Low** | Plain HTTPS, no platform coupling. |
| Roaming physics (`GravitySimulator`, window topology via `CGWindowList`) | Physics: direct port. Topology: `EnumWindows` + `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` | Medium-High | The trickiest macOS-specific piece: solid-rect window topology, ledge grabs, ceiling clamps. `EnumWindows` gives layer-z filtering (skip cloaked/`WS_EX_TOOLWINDOW`); the menu-bar-stuck class of bug maps to the taskbar and needs the same clamp-to-workarea rule from day one. |
| Menu-bar status item | System tray icon (`Shell_NotifyIcon`) + context menu | Low | Standard. |
| Launch at login (`SMAppService`) | Registry `Run` key or StartupTask | Low | |
| Global hotkey (Carbon) | `RegisterHotKey` | Low | Simpler than Carbon, honestly. |

## Language & runtime choice

**C# / .NET 8 + WinUI 3 (or WPF for the overlay window, which is the pragmatic
choice for per-pixel-alpha layered windows).** Reasons:

- The logic half of this app (state machines, dialogue, JSON pools, HTTP
  monitors) is a *natural* C# port, and the ecosystem for Win32 interop
  (`CsWin32`, `Vanara`) is excellent.
- Swift on Windows remains a moving target for GUI apps; using it would spend
  the porting budget fighting the toolchain instead of shipping the pet.
- WebView2 has first-class .NET bindings, which keeps the ChatGPT bridge — the
  app's heart — low-risk.

## Milestones (each independently demoable)

1. **M-W1 — Sprite on screen.** Layered always-on-top window, click-through
   outside the silhouette, idle animation loop at 30fps, drag to move.
   *Demo: Bill standing on the Windows desktop, bobbing.*
2. **M-W2 — The brain, ported.** `BillStateMachine` + clip library + dialogue
   JSON + bark bubbles (the hand-built pixel font and the layered-border
   renderer, ported to Direct2D/Skia). *Demo: scripted barks, reaction states.*
3. **M-W3 — The desktop is furniture.** Window topology via `EnumWindows`,
   gravity sim, roaming/climbing with the same goal planner. Includes the
   workarea-clamp (menu-bar lesson applied to the taskbar up front).
   *Demo: Bill walking the taskbar, climbing a window, falling.*
4. **M-W4 — The bridge.** WebView2 hosting chatgpt.com, the JS bridge scripts
   injected verbatim, the pixel chat window (scroll fix included from day one).
   *Demo: full ChatGPT-powered chat through Bill's speech bubbles.*
5. **M-W5 — Awareness.** UIA window titles, volume monitor, battery/power
   events, weather pull, the reaction router wiring them to the state machine.
6. **M-W6 — Personalization + polish.** First-run app-study flow, tray menu,
   settings surface, the minimize prank (UIA Invoke), packaging (MSIX + a
   portable zip), CI on `windows-latest`.

## Risks & honest unknowns

- **chatgpt.com in WebView2**: same site, same engine family as the Mac path's
  WebKit — but not the *same engine*. The DOM heuristics should hold; the
  sign-in/cookie story needs one real device test. Flagged as the first thing
  to prototype in M-W4.
- **Per-pixel-alpha + hit-test reliability** across Windows 10/11 and
  multi-DPI setups — the classic desktop-pet quagmire; M-W1 exists to flush it
  out before anything else is built on top.
- **Auto-start + unsigned-binary treatment** (SmartScreen) — an MSIX identity
  helps; a signing cert is a real cost decision for later.

## Non-goals for the port

- No feature parity freeze: the Mac app keeps moving; the port tracks
  *milestones*, not commits.
- No cross-platform UI framework midway — if the port starts in WPF/Direct2D,
  it stays there; a mid-port migration to WinUI 3 would be a rewrite of the
  rewrite.
