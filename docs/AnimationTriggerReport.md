# Bill's animation library — what each one is and what fires it
Generated from the source, not written by hand: states from `BillState.swift`, clips and loop modes from `AnimationClipLibrary.swift`, frame counts from `BillSpriteCatalog.swift`, triggers from `ReactionRouter.swift`, `SpecialAppMapper.swift`, `StudyMode.swift` and `RoamingController.swift`.

**74 states, 74 clips, every state has a clip and every state has at least one trigger.**

Loop column: `once` = plays and settles back to idle · `loop` = runs until something replaces it.

| State | Sheet group | Frames | Loop | Frame time | What fires it |
|---|---|---:|---|---:|---|
| `idle` | 01 idle float/hover | 7 | loop | 0.15s | idle beat; click / drag / chat; system event |
| `walking` | 16 bang startle walk | 6 | loop | 0.16s | desktop roaming (physics) |
| `talking` | 03 talking gesture | 3 | loop | 0.15s | category communication; click / drag / chat |
| `thinking` | 31 eye opening focus | 4 | loop | 0.35s | category coding; click / drag / chat |
| `happy` | 47 tongue out tease | 2 | once | 0.16s | category music; charging / battery rising; network restored or improved; study.halfway; volume 0/25/50/75/100 + mute; click / drag / chat |
| `annoyed` | 02 rage whipcrack stagger | 6 | once | 0.16s | battery falling (5% steps); homework / learning / fun nag; refocus #2; study.blocked2 |
| `sleeping` | 01 idle float hover | 1 | pingpong | 0.12s | system event |
| `gaming` | 12 cane flourish | 1 | pingpong | 0.12s | category gaming |
| `coding` | 31 eye opening focus | 2 | loop | 0.22s | category coding |
| `channeling` | 41 blue flame channel | 9 | loop | 0.15s | category tinkering; study.start |
| `focused` | 31 eye opening / focus | 4 | once | 0.2s | category coding; category finder; category productivity; half-hour chime; study.start |
| `heatingUp` | 38 shock fire ashen escalation | 7 | loop | 0.2s | system event |
| `charging` | 17 power charge-up | 1 | pingpong | 0.12s | charging / battery rising |
| `surprised` | 16 bang startle walk | 3 | once | 0.18s | volume 0/25/50/75/100 + mute; click / drag / chat |
| `celebrating` | 35 cane flourish overhead lasso | 5 | once | 0.14s | category gaming; charging / battery rising; network restored or improved; study.halfway |
| `confused` | 08 green eye queasy | 4 | once | 0.18s | category browsing; category finder; battery falling (5% steps); network lost or degraded |
| `dazed` | 29 dizzy tumble | 2 | once | 0.22s | network lost or degraded; click / drag / chat |
| `poked` | 07 duck flinch | 4 | once | 0.11s | click / drag / chat |
| `smug` | 45 snap gesture B | 3 | once | 0.2s | category aiChat; half-hour chime; refocus #1; idle beat; system event |
| `caneFlourish` | 12 cane flourish | 8 | once | 0.13s | volume 0/25/50/75/100 + mute; idle beat |
| `powerSurge` | 30 portal ring cycle | 8 | once | 0.09s | charging / battery rising; rare Easter egg + daily coverage sweep |
| `zodiacVision` | 04 zodiac dial | 8 | once | 0.3s | half-hour chime; rare Easter egg + daily coverage sweep |
| `summonRitual` | 23 ritual clone circle | 4 | once | 0.25s | rare Easter egg + daily coverage sweep |
| `ghostPale` | 28 ghost materialize to true form | 8 | once | 0.2s | rare Easter egg + daily coverage sweep |
| `glitchForm` | 48 glitch monochrome red eye | 4 | once | 0.08s | network lost or degraded; rare Easter egg + daily coverage sweep |
| `shadowHands` | — | ? | once | 0.3s | study.blocked3; rare Easter egg + daily coverage sweep |
| `meltdown` | 39 pale appear and melt | 8 | once | 0.15s | study.blocked3; rare Easter egg + daily coverage sweep |
| `trickster` | 14 physical form transform | 8 | once | 0.15s | app: com.tobyfox.undertale; category gaming |
| `darkWorld` | 36 flex then chaos vortex | 9 | once | 0.17s | app: com.tobyfox.deltarune |
| `hollowed` | 22 feral beast mode | 11 | once | 0.16s | app: unity.Team Cherry.Hollow Knight |
| `cultLeader` | 24 true form summon buildup | 8 | once | 0.17s | app: com.Massive-Monster.Cult-Of-The-Lamb; homework / learning / fun nag; study.blocked3; study.start |
| `spooked` | 08 green eye queasy | 5 | once | 0.13s | app: baldi; network lost or degraded |
| `scanning` | 09 claw creeping up | 8 | once | 0.13s | app: com.altillimity.satdump, oorg.sdrpp.sdrpp; category browsing; category finder; category tinkering; half-hour chime |
| `sneaking` | 20 sneak crouch cycle | 6 | loop | 0.14s | app: org.wireshark.Wireshark |
| `glitching` | 48 glitch monochrome red eye | 4 | loop | 0.14s | app: com.utmapp.UTM; category aiChat; network lost or degraded |
| `charged` | 46 shock spike aura | 6 | once | 0.14s | app: com.yourcompany.qFlipper; charging / battery rising; network restored or improved |
| `transferring` | 13 vanish snap return | 12 | once | 0.09s | app: com.raspberrypi.rpi-imager, io.balena.etcher; category tinkering; charging / battery rising |
| `summoning` | 18 hypnotic eye cast | 8 | once | 0.14s | app: com.electron.dockerdesktop; category tinkering; study.start |
| `sculpting` | 19 stone tower transform | 14 | once | 0.16s | app: org.blenderfoundation.blender; category creative; category productivity |
| `kinship` | 27 conjures fuzzy creature | 5 | once | 0.13s | app: com.orama-interactive.pixelorama; category communication; category creative; study.halfway; volume 0/25/50/75/100 + mute |
| `fractaling` | 36 flex then chaos vortex | 3 | once | 0.2s | app: com.jasonilization.mandelbrotexplorer; network restored or improved |
| `presenting` | 06 sway presenting pill | 3 | once | 0.17s | app: canva; category creative; category productivity; half-hour chime; refocus #1; study.halfway |
| `guilty` | 07 duck flinch | 3 | once | 0.2s | app: duolingo; homework / learning / fun nag; refocus #3 |
| `dreading` | 08 green eye queasy | 4 | once | 0.16s | app: classroom, shrewsbury, socs, student; category productivity; battery falling (5% steps); homework / learning / fun nag; refocus #3; study.blocked2 |
| `grooving` | 47 tongue out tease | 3 | once | 0.15s | app: youtube; category music; volume 0/25/50/75/100 + mute |
| `dispatching` | 45 snap gesture B | 4 | once | 0.14s | app: com.apple.mail; category communication; half-hour chime |
| `ambushed` | 16 bang startle walk | 8 | once | 0.13s | app: com.apple.AppStore; network lost or degraded |
| `stressed` | 38 shock fire ashen escalation | 7 | once | 0.16s | app: com.apple.ActivityMonitor; battery falling (5% steps); homework / learning / fun nag; refocus #3; study.blocked2 |
| `watched` | 34 idle into lunge reaction | 5 | once | 0.16s | app: com.apple.systempreferences; category aiChat; category browsing; battery falling (5% steps); half-hour chime; refocus #1; study.blocked1 |
| `flinching` | 07 duck flinch (3-frame squash) | 3 | once | 0.13s | app: com.apple.PhotoBooth; volume 0/25/50/75/100 + mute |
| `huffy` | 02 rage whipcrack stagger | 6 | once | 0.11s | app: net.freemacsoft.AppCleaner; battery falling (5% steps); homework / learning / fun nag; refocus #2; study.blocked1 |
| `pushingCode` | 05 whip cast | 6 | loop | 0.1s | app: github; category coding |
| `browsingStore` | 06 sway presenting | 3 | loop | 0.1s | app: com.valvesoftware.steam; category gaming |
| `dancing` | 06 sway / presenting | 7 | once | 0.12s | app: com.spotify.client; category music; volume 0/25/50/75/100 + mute |
| `caneTwist` | 21 cane flourish (eyes closed) | 8 | once | 0.13s | half-hour chime; rare Easter egg + daily coverage sweep |
| `hookCane` | 25 hook cane variants | 5 | once | 0.18s | half-hour chime; rare Easter egg + daily coverage sweep |
| `conjuring` | 27 conjures fuzzy creature | 18 | once | 0.15s | category creative; half-hour chime; rare Easter egg + daily coverage sweep |
| `tumbling` | 29 dizzy tumble | 4 | once | 0.15s | rare Easter egg + daily coverage sweep |
| `dashTarget` | 32 dash lunge (target emblem) | 4 | once | 0.11s | rare Easter egg + daily coverage sweep |
| `grumpEyes` | 33 anger buildup wide eye | 6 | once | 0.15s | battery falling (5% steps); homework / learning / fun nag; refocus #2; study.blocked1; rare Easter egg + daily coverage sweep |
| `zipAround` | 37 idle quick zip | 11 | once | 0.11s | network restored or improved; rare Easter egg + daily coverage sweep |
| `rampaging` | 42 red rampage run | 10 | once | 0.11s | study.blocked3; rare Easter egg + daily coverage sweep |
| `crouching` | 07 duck flinch (3-frame squash) | 3 | once | 0.06s | desktop roaming (physics) |
| `launching` | 07 duck flinch (3-frame squash) | 3 | once | 0.055s | desktop roaming (physics) |
| `rising` | 07 duck flinch (3-frame squash) | 1 | loop | 0.2s | desktop roaming (physics) |
| `falling` | 29 dizzy tumble | 4 | loop | 0.1s | desktop roaming (physics) |
| `landingSoft` | 07 duck flinch (3-frame squash) | 3 | once | 0.075s | desktop roaming (physics) |
| `landingHard` | 07 duck flinch (3-frame squash) | 3 | once | 0.07s | desktop roaming (physics) |
| `ledgeGrabbing` | 20 sneak crouch cycle | 6 | once | 0.08s | desktop roaming (physics) |
| `climbingUp` | 20 sneak crouch cycle | 6 | loop | 0.13s | desktop roaming (physics) |
| `climbingDown` | 20 sneak crouch cycle | 6 | loop | 0.15s | desktop roaming (physics) |
| `hangingIdle` | 20 sneak crouch cycle | 1 | loop | 0.3s | desktop roaming (physics) |
| `edgePeek` | 31 eye opening / focus | 4 | once | 0.16s | desktop roaming (physics) |
| `running` | 42 red rampage run | 10 | loop | 0.08s | desktop roaming (physics) |

## Caveats on this table

- Frame counts are the **source group** size. A few clips deliberately use one
  frame out of a larger group (`gaming` holds a single cane pose, `rising` holds
  one upright frame), and a few build their texture array from more than one
  group (`shadowHands` combines groups 44 and 49, `powerSurge` chains the portal
  ring into the surge into a held close-up) — those show `—`/`?` above.
- "Sheet group" is the white-boxed region on the original sprite sheet, matching
  the labelled files in `AnimationReview/`.

## Is every animation used, and used usefully?

**Yes, with one honest qualification.** All 74 states have a clip and at least
one real trigger. But "has a trigger" and "you will actually see it" are
different claims, so here is the breakdown by how often each group genuinely
surfaces:

| Tier | Count | How you see them |
|---|---:|---|
| Constant | 13 | idle, walking, running, and the 10 physics beats — every roaming trip |
| Frequent | 27 | app categories, battery steps, volume marks, network, the half-hour chime, refocus, click/drag/chat |
| App-specific | 27 | fire when you open that specific app (Blender, Docker, Duolingo, Steam, Wireshark…) |
| Rare + swept | 15 | Easter eggs — low-probability roll, **plus** the daily coverage sweep |

The overlap is deliberate: most states appear in more than one tier, which is
what stops any single trigger looking the same twice.

### The once-a-day guarantee, stated honestly

`AnimationCoverage` persists the last-played date per state and paces a
background sweep at `remaining time before 23:00 ÷ animations still owed`
(clamped to 90s…20min), preferring whatever has gone longest without a day on
screen. Combined with `pick(from:)` refusing to return the state that just
played, that means:

- **Guaranteed:** no animation repeats back-to-back, anywhere, on any trigger path.
- **Guaranteed while Bill is running and idle-reachable:** every showcaseable
  animation gets its turn each day.
- **Not guaranteed:** a day where the Mac is barely switched on. Bill can only
  perform while he is running. Leftovers are *not* silently marked as seen —
  they carry over, and `daysShown` biases them to the front of tomorrow's queue.

Excluded from the sweep on purpose: the 12 physics states (showing a falling
frame while standing still reads as a glitch), plus `idle`, `sleeping`,
`charging` and `heatingUp` — those are *conditions*, and faking them would be
lying about the machine's state.

### Sheet groups that are not character animations

Six of the fifty white-boxed regions are reference material rather than
performances — a zodiac-dial reference sheet, HP-ring UI chrome, an HP-stage
palette reference, a portrait close-up block, a palette-select grid, and a
form-portrait-select grid (which contains an unrelated red crab enemy). They are
not wired to triggers, and forcing them into one would put UI furniture on your
desktop.
