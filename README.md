# Bill Cipher — Desktop Companion for macOS

<p align="center">
  <img src="docs/assets/bill-demo.gif" width="236" alt="Bill summoning the Zodiac wheel">
</p>

<h3 align="center">Bill Cipher lives on your desktop.</h3>

<p align="center">He studies your apps, watches the sky, presses buttons he shouldn't, and chats back through his own pixel speech bubbles.</p>

<p align="center">
  <a href="https://github.com/Jasonilization/bill-cipher-companion/releases/latest"><b>Download the DMG</b></a> · <a href="https://jasonilization.github.io/bill-cipher-companion/">Homepage</a> · <a href="https://jasonilization.github.io/bill-cipher-companion/animations.html">Every animation, looping</a></p>

<p align="center">
  <a href="https://github.com/Jasonilization/bill-cipher-companion/releases/latest"><img src="https://img.shields.io/github/v/release/Jasonilization/bill-cipher-companion?style=flat-square" alt="Release"></a>
  <a href="https://github.com/Jasonilization/bill-cipher-companion/releases"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-333333?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+"></a>
  <a href="https://github.com/Jasonilization/bill-cipher-companion/actions"><img src="https://img.shields.io/github/actions/workflow/status/Jasonilization/bill-cipher-companion/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-000000?style=flat-square" alt="MIT"></a>
</p>

---

A hand-drawn **380-sprite pixel-art rig** of Gravity Falls' dream demon, native Swift end to end (AppKit + SpriteKit + WebKit), with desktop physics, app awareness, weather, and a real ChatGPT session behind the chat.

> *Unofficial, non-commercial fan project. Bill Cipher and Gravity Falls are © Disney. Not affiliated with or endorsed by Disney.*

## What he does

- **Studies your apps (first-run personalization)** — Bill offers to use his own ChatGPT connection to write himself commentary for the apps actually installed on your Mac: a morning line, a midday line, an afternoon line and a night line for each app, plus transition quips for switching between your most-used pairs. All in his voice, all referencing Gravity Falls lore, all generated on your machine — and merged into his live dialogue immediately, batch by batch.
- **Reads the sky** — pulls local weather (Open-Meteo, keyless) every five minutes using the radar-based nowcast, so he announces rain *while it's actually starting to rain*, and folds today's conditions into his chat context.
- **Roams the whole screen** — walks the floor, climbs windows, perches on them, falls with gravity, and gets shoved aside when you move windows under him. Shooting animations keep him anchored where he was standing.
- **Presses the minimize button** — very occasionally, Bill leaps onto a background window's yellow traffic light, plays a satisfied finger-snap, and *actually minimizes the window* — then falls through where its top edge used to be. Never the window you're working in; toggleable in Settings.
- **Incognito browsing reaction** — open a private/incognito window in any browser and Bill triggers the red shooting cloud with custom dialogue ("*what you searching up online this late? better not be as weird as Dipper's search history!*"). This is the ONLY trigger for that animation.
- **Knows what you're up to** — reads your focused window's title (via Accessibility) and, if you opt in, can read the window contents on-device (Vision OCR) to tell whether your assignments are actually done.
- **Talks to you** — right-click Bill → **Talk** (or the global hotkey, or the menu bar). Fixed-size pixel-styled chat window with scrollable messages, dot-matrix header, and a pixel border. Conversations scroll, the composer wraps, nothing ever gets clipped.
- **Directional speech bubbles** — bark bubbles float beside, above, or below Bill in their own panel: random direction when there's room, away from the border when near one.
- **Actually chats** — replies come from a real ChatGPT session in an embedded WebKit view, with a summary of your recent Mac activity *and* the current weather folded into the first message of each conversation.
- **Never runs out of things to say** — a background prompt asks ChatGPT for fresh, activity-relevant quips **spread across the day** (1–6× per day, your call) and merges them into the local dialogue pools.
- **Has moods** — poke him too much and watch. All 66+ animation families play from idle, tiered by rarity. Pin any reaction to a favourite animation in Settings, or assign animations per-app.
- **Menu bar citizen** — a proper `LSUIElement` accessory app: no Dock icon, no focus stealing, lives quietly in the menu bar. Trust no one; trust the eye.

## Make him yours

Settings is a proper control surface: recolour his speech bubbles, scale the bark text, resize the chat window, dial the idle-animation pacing, pin individual reactions to specific animations, assign animations to specific apps, set how many times a day his prompts refresh, and write extra persona instructions that ride along with every prompt (chat, refreshes, personalization). Test triggers let you fire any reaction live. Everything applies immediately.

## Requirements

| | |
|---|---|
| **OS** | macOS 14 (Sonoma) or newer. On the newest systems Bill gets Liquid Glass and the modern WebKit `WebPage` engine; on older Macs he automatically falls back to a classic `WKWebView` bridge and material chrome — same behavior, same tricks, no setup |
| **Chat** | a logged-in [chatgpt.com](https://chatgpt.com) account (Bill opens his own browser window for the one-time sign-in) |
| **Perms** | Accessibility (window titles), optional Screen & Audio capture (OCR) — asked for on first use |

## Install

1. Download **`Bill-macOS.dmg`** from the [latest release](https://github.com/Jasonilization/bill-cipher-companion/releases/latest).
2. Open the DMG and drag **Bill** onto the **Applications** shortcut beside him.
3. First launch: **right-click → Open** (the app is ad-hoc signed, not notarized).
4. Look at your menu bar. He's already watching your desktop — and shortly he'll offer to study your apps.

## Build from source

```bash
git clone https://github.com/Jasonilization/bill-cipher-companion.git
cd bill-cipher-companion
swift build                # debug
./Scripts/bundle.sh release  # → Bill.app, ad-hoc signed
```

No Xcode project — a pure SwiftPM package (`swift-tools-version: 6.2`, deployment target `.macOS(.v14)`).

## How it's put together

```
Sources/Bill/
├── Animation/        SpriteKit rig, state machine, 380-sprite catalog, FX library
├── App/              NSApplication bootstrap, menu-bar + monitor wiring
├── Awareness/        Focused-window titles + on-device OCR (Vision)
├── CharacterEngine/  Bark lines, reactions, habit nagging
├── Chat/             WebKit/ChatGPT bridge, injected JS, message relay
├── Debug/            Dialogue refresh log window
├── Dialogue/         Local dialogue pools, time-of-day lines
├── Memory/           Recent-activity summaries (context for chat)
├── Personalization/ First-run ChatGPT setup: per-app, per-time, transition lines
├── Roaming/          Desktop physics: ledges, gravity, window-climbing
├── StudyMode/        Focus enforcement
├── SystemMonitor/    Battery / network / CPU / idle / volume / weather
└── UI/               Character window, pixel chat, bark panels, settings, hotkey
```

## Windows

A Windows port is in progress (WPF, milestones W1–W3). Preview available in `windows/` — see [the port plan](https://github.com/Jasonilization/bill-cipher-companion/blob/main/docs/notes/WindowsPortPlan.md).

## License

Code is released under the [MIT License](LICENSE). The character Bill Cipher and all Gravity Falls references belong to Disney. The pixel sprites are used for this non-commercial fan project with credit to their creators:

**Bill Cipher sprite artwork** — original artwork by **Kelly Nora** ([@kiernenking](https://www.deviantart.com/kiernenking)); sprite sheet by **JayHyperStarX**, from ["Bill Cipher – Sprite Sheet" on DeviantArt](https://www.deviantart.com/jayhyperstarx/art/Bill-Cipher---Sprite-Sheet-910916786).

---

*Reality is an illusion, the universe is a hologram, buy gold, bye!*
