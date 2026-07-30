# Bill Sprite Sheet — Analysis & Animation Catalog

Source: `Bill cipher Sprite sheet.png` (1978×2976, RGBA, transparent background).
Analysis method: full visual survey (16 tiled regions covering the entire sheet)
cross-referenced against programmatic connected-component detection (alpha-channel
based, via `scipy.ndimage.label`) for pixel-exact frame boundaries — 351 individual
sprite components were detected sheet-wide, further sub-clustered into ~70 distinct
sequences by row-band and x-gap grouping. All coordinates below are `(x0, y0, x1, y1)`
in original sheet pixels.

This document was written after the **first** extraction pass and has since been
updated to reflect a **second, much larger pass** that replaced every remaining
procedural-transform-only or vector-prop-only state with real sprite frames, fixed
a body-clipping/snapping bug, and added a set of rare, low-frequency Easter-egg
animations. See "Second pass" below for what changed and why.

## What's actually on this sheet

This is not simple promotional art — it's a dense rip from what is clearly a
fan-made Gravity Falls boss-fight game: alongside ordinary idle/walk/gesture
cycles there's a full combat kit (punches, projectile magic, hypnosis eyes,
summoning circles), multiple large story-specific transformations (a brick-textured
"physical form", a stone ziggurat tower, a many-eyed "true form" with wound/blood
states), palette-swapped NPC variants, an unrelated enemy creature, a zodiac dial,
and UI chrome (HP rings, portrait frames). Per the project's explicit instruction —
"the sprite sheet is the character," don't discard content, give even strange
animations a purpose as a rare event if a literal 1:1 state mapping doesn't fit —
almost everything usable now backs *some* state; what's left out is listed at the
bottom with the reason.

## First pass — core states, pixel-exact coordinates

| Animation | Frames | Coordinates (x0,y0,x1,y1) | What Bill is doing | Assigned state(s) |
|---|---|---|---|---|
| **Idle stand** | 7 | (10,20,48,88) (52,19,90,87) (93,20,136,86) (146,19,203,82) (208,18,262,81) (265,19,320,82) (324,17,379,80) | Standing, near-identical resting poses with tiny limb variance | `idle` (base/rest texture) |
| **Walk cycle** | 4 | (233,1164,301,1223) (318,1166,442,1226) (446,1169,503,1228) (512,1169,569,1228) | Clean run-cycle, legs alternating, arms swinging | `walking`, and frame 2 (arm raised) doubles as the base pose for `gaming` |
| **Angry/fist** | 3 | (416,15,457,83) (456,11,497,83) (496,7,537,83) | Frown, one fist raised, escalating | `annoyed` |
| **Arms-up cheer** | 2 | (60,2031,110,2094) (125,2038,170,2096) | Both arms thrown straight up | `happy`; also ping-ponged over 3 cycles for `celebrating` (+confetti/sparkle FX) |
| **"?" confusion burst** | 1 | (184,2028,246,2098) | Black silhouette, spark outline, white "?" | `confused` |
| **Fire body** | 3 | (254,2035,310,2084) (321,2035,377,2084) (391,2036,447,2085) | Body progressively textured with flame/red | `heatingUp` (+steam FX overlay) |
| **Lounge & relax** | 1 | (5,2581,83,2657) | Reclining on a beach chair, sunglasses, popcorn | `charging` |
| **Hat-flies-off shock** | 1 | (324,1969,387,2031) | Startled, hat mid-air, arms flailing | `surprised` |
| **Tongue out** | 4 | (13,2671,68,2734) (72,2671,142,2734) (144,2671,198,2734) (203,2671,258,2734) | Sticks tongue out, teasing | `poked` (click reaction) |
| **Dizzy/dazed** | 2 | (559,18,607,82) (617,19,661,79) | Crossed eyes, unsteady stance | `dazed` (brief post-surprise recovery beat) |

## Second pass — replacing every remaining placeholder with real frames

The first pass left several states running on procedural-transform-only poses or
vector props (`thinking`, `talking`, `sleeping`, `gaming`, `coding`) instead of
dedicated sprite sequences, and left several unusual sequences (zodiac dial,
summoning circle, power-surge/many-eyed burst) sitting unused. Both were flagged
as unacceptable: every state needed real backing art, and nothing usable should be
discarded. This pass re-surveyed the full sheet and pulled the following additional
groups (frame counts and content verified by direct visual inspection; exact
per-frame source coordinates from this pass were not retained in this document —
the extraction script that captured them was a scratch tool, not part of the repo,
but the resulting frames themselves are committed under
`Sources/Bill/Resources/Sprites/` and are the source of truth going forward):

| Animation | Frames | What Bill is doing | Assigned state(s) |
|---|---|---|---|
| **Hand-to-chin thinking** | 4 | A genuine "pondering" gesture — hand raised to chin, head tilted, held and released | `thinking` (replaces the old idle+tilt transform hack) |
| **Wave / greeting** | 5 | Arm raised and waved in a clear hello/attention-getting motion | `talking` (ping-ponged) — replaces the old procedural bob |
| **Lying down / asleep** | 1 | Genuinely horizontal, eye shut, restful pose | `sleeping` (replaces the old "idle frame with squashed eye" hack) |
| **Crouched, typing-like arm motion** | 2 | Hunched forward, arms working in front of the body — reads as "at a keyboard" without an actual prop | `coding` (replaces the old vector-laptop prop) |
| **Smug / self-satisfied** | 2 | Arms-crossed-adjacent confident pose | `smug` (new — a light, frequent personality beat, not a rare event) |
| **Many-eyed power surge** | 4 | The sheet's "true form" burst — multiple eyes, dramatic pose | `powerSurge` (new — rare Easter egg) |
| **Zodiac dial** | 4 | The ornate zodiac wheel with Bill's silhouette overlaid, dial appearing to turn | `zodiacVision` (new — rare Easter egg) |
| **Summoning circle** | 1 | Bill standing in a glowing ritual circle | `summonRitual` (new — rare Easter egg, held on screen ~2.4s given it's a single dramatic frame rather than a cycle) |

`gaming` did not get a new dedicated sequence — the existing walk-cycle's
arm-raised frame (already catalogued above) reads correctly as "holding something
up" once the vector controller prop was removed, so it was repointed there instead
of pulling a redundant frame.

### Fixing the clipping/snapping bug

The user's central complaint about the first pass: *"Bill extends his arms, but the
main body suddenly clips back or changes size... looks like a rendering bug."* Root
cause — every frame had been cropped tightly to its own individual bounding box, so
a wide arms-out frame and a narrow idle frame had different pixel dimensions and
different centers. `SKAction.setTexture(_:resize:true)` resizes the node to match
each incoming texture, so the node's rendered center visibly shifted every time the
texture swapped.

**Fix:** every frame across the entire catalog (all ~18 groups) is re-exported onto
one shared global canvas — **124×115px**, the max width/height needed by any single
frame — with Bill's silhouette bottom-center-aligned within it, baked into the PNG
at export time. Every texture now has identical dimensions, so swapping textures
never changes node size, and the default `(0.5, 0.5)` anchor point works correctly
with no further SpriteKit-side compensation needed. See `BillRigNode.swift`'s doc
comment for the implementation-level explanation.

### Retiring vector props entirely

Per "everything visible should use the pixel-art Bill style, no procedural props,"
`AnimationClipLibrary.prop(for:)` now always returns `.none`. `gaming`, `coding`,
and `charging` no longer mount a vector controller/laptop/charger-cable — the
sprite frames themselves (arm-raised pose, crouched-typing pose, lounging pose)
carry the meaning instead. `PropKit.swift` is unused dead code as of this pass,
kept only because deleting a whole file wasn't necessary to satisfy "pixel art
only" (nothing references it anymore); `FXLibrary`'s particle effects (steam,
sparkle, zzz, confetti) are unaffected — those were never vector *props*, and
particles over pixel art read fine.

### Rare Easter eggs

`powerSurge`, `zodiacVision`, and `summonRitual` fire from `CharacterEngine`'s idle
beat: a 3% chance per beat, gated by a 10-minute cooldown so they can never appear
back-to-back or overwhelm normal idle variety. `smug` is a lighter, more frequent
personality beat (12% chance per idle beat, no cooldown) since its source frames
read as a normal expressive moment rather than a dramatic reveal.

## Pixel chat system (replaces raw ChatGPT web UI as the primary interaction)

The ChatGPT bridge (`Chat/ChatBridge.swift`) still drives the real, logged-in
chatgpt.com session exactly as before — that didn't change. What changed is the
*visible* interaction: right-clicking Bill (or the global hotkey, or "Talk to
Bill" in the menu bar) opens `PixelChatInputPanel`, a small stepped-border pixel
input box positioned just above his head. Typing and pressing Return sends the
text through the existing bridge (`ChatBridge.send(_:)`, which prepends a persona
preamble on the first message of a session so ChatGPT's own replies take on
Bill's voice); the reply comes back through `BarkBubble` — the same genuinely
pixel-art speech bubble used for ambient reactions, not a browser window. The full
web view (`ChatPanelController`/`ChatPanelView`) still exists and is reachable
from the menu bar as "Open Full Chat View…" for anyone who wants the raw ChatGPT
UI, but it's no longer the default/primary path.

## Cross-checked against the required state list

- Core: idle✓, blinking (transform trick)✓, walking✓, looking around (idle-variant
  reuse), talking✓(real wave frames), thinking✓(real hand-to-chin frames), happy✓,
  annoyed✓, surprised✓, confused✓, sleepy → folded into `sleeping`✓(real frame).
- System reactions: coding✓(real frames), gaming✓(real frame, no prop),
  browsing (bark-only, unchanged), music → reuses `happy`, creative → reuses
  `coding` pose, high CPU → `heatingUp`✓, low battery → reuses `annoyed`,
  charging✓(real frame, no prop), WiFi problem → `confused`✓.
- Personality: celebrating✓, curious → folded into idle look-variants, dazed✓,
  smug✓(new), powerSurge✓(new, rare), zodiacVision✓(new, rare),
  summonRitual✓(new, rare). **Still not implemented**: laughing, chaotic,
  suspicious, dramatic-reaction as *distinct* states — the rare-event trio above
  covers "dramatic/chaotic" in spirit; a literal 1:1 mapping for the remaining
  names wasn't backed by a clean, unambiguous frame group on this sheet.

## Explicitly not used (present on the sheet, wrong fit for a companion)

The brick-textured "physical form" transformation, the stone ziggurat tower boss
form, the many-eyed "true form"'s wound/blood damage states specifically (the
non-damage many-eyed burst *is* now used, as `powerSurge`), palette-swapped
costume/NPC variants, the unrelated enemy creature, hypnosis-eye and punch/whip
combat frames, and all HP-ring/portrait UI chrome. These are real, well-drawn
animations — just not ones that fit an ambient desktop companion even as a rare
event (they're either combat-specific, story-specific, or UI chrome rather than a
character pose).

## Implementation notes

- Frames are cropped from the source sheet and re-exported onto a shared
  124×115px canvas (see "Fixing the clipping/snapping bug" above), one PNG per
  frame, into `Sources/Bill/Resources/Sprites/`, bundled via SwiftPM's
  `resources: [.copy(...)]` (`Bundle.module`).
- Every `SKTexture` gets `filteringMode = .nearest` in `BillSpriteCatalog` —
  this is what keeps scaling crisp/blocky instead of smoothed; it's set once,
  centrally, so no call site can accidentally reintroduce blur.
- Displayed at `BillRigNode.displayScale = 1.9×` the source pixel size.
- The architecture around the body didn't change: `BillStateMachine`'s public
  interface (`request`, `playIdleVariant`, `showBark`, `onActivityChanged`,
  `debugDump`) is the same as before sprite integration, so `CharacterEngine`,
  `ReactionRouter`, `SystemMonitor`, memory, and settings needed no changes for
  the animation work. `ChatBridge` gained `send(_:)`/`onResponseReceived` for the
  pixel chat system, but its existing `isGenerating`/`isLoading`/`page`
  publishers are unchanged.
- Any clip for a state where `BillState.isContinuous == false` **must** use
  `loop: .once` (repeating its own texture array manually for a multi-cycle feel
  if needed, via the `pingpong(_:cycles:)` helper in `AnimationClipLibrary`) —
  `BillStateMachine.runClip` only schedules its auto-settle-to-idle timer for
  `.once` clips. `celebrating` originally shipped with `.pingpong` while
  non-continuous and got stuck playing forever; this is now a documented hard
  rule specifically to prevent that recurring in `dazed`/`smug`/`powerSurge`/
  `zodiacVision`.
