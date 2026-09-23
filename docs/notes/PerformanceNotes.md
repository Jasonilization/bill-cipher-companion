# Performance: what runs, how often, and what changed

The standing requirement was to check after each step that nothing eats CPU,
GPU or RAM. This is the accounting.

## Always-on periodic work

| Source | Before | After | Notes |
|---|---|---|---|
| Click-through poll | **0.1s, always** | 0.4s far / 0.1s near | The cursor is far from Bill almost all the time, so the usual rate is now 2.5 Hz. Steps up automatically inside a 260pt band. |
| Cursor-proximity poll | 2.5s, always | **removed** | Existed only to emit a non-contextual bark. Timer and feature both deleted. |
| CPU sample | 10s | 10s | One `host_statistics` call. Unchanged. |
| User-idle sample | 30s | 30s | One `CGEventSource` read. Unchanged. |
| Idle animation beat | 4–9s | 4–9s | Now animation-only; emits no speech. |
| Roaming rest timer | 15–32s | 11–26s | One-shot, self-rescheduling. |
| Dialogue refresh check | 30min | 30min | Unchanged. |
| Animation catch-up | — | 90s–20min, adaptive | New. Paces itself against the backlog; when nothing is owed it sleeps 30 min. |
| Half-hour chime | — | 48 wakeups/day | New. Aligned to the wall clock, so it is one timer re-armed at each boundary, not a poll. |

**Net: one always-on timer removed, and the highest-frequency one cut by 4x in
the common case.**

## Work that only exists while something is happening

| Source | Rate | Runs when |
|---|---|---|
| Roaming physics tick | 60 Hz | Only during a movement beat (a few seconds, a few times a minute). Invalidated at rest — **zero** wakeups when Bill is standing still. |
| Network quality dwell | one-shot 25s | Only while a tier change is pending. |
| Study Mode | 15-min milestones | Only during a session. |
| Chat watchdog / typing dots | 5s / 0.45s | Only while a reply is awaited. |

## Push-driven — no polling at all

`NWPathMonitor`, `CWWiFiClient.linkQualityDidChange`, `IOPSNotificationCreateRunLoopSource`,
CoreAudio property listeners, `NSWorkspace` activation/wake notifications, and
the Carbon hot key. All of these cost nothing until the thing they watch changes.

## Render loop

Previously a flat 30fps that **never paused**: `setClipActive(false)` was never
called anywhere, and ambient idle animates forever by design, so the documented
"pause while idle" optimisation was unreachable in two independent ways.

Now: **12fps while only the ambient bob is running, 30fps for real clips, barks
and roaming.** The bob's content changes ~6.7 times a second (7 frames at
0.15s), so 12fps loses nothing visible. Idle dominates the runtime, so this is
where the GPU time actually was.

## Disk

`MemoryStore.save()` ran a synchronous `JSONEncoder` plus an atomic rewrite of a
~16KB file **on the main actor, on every app activation** — so rapid Cmd-Tabbing
produced a burst of main-thread file writes. Now coalesced to one write a second
after the last change, with the write itself off the main actor, plus a
synchronous flush on terminate so nothing is lost on quit. `AnimationCoverage`
and the refresh log use the same pattern.

## Memory

- 376 sprite PNGs on a shared 118x111 canvas, loaded lazily per group. **No new
  sprite art was added** — every one of the 12 new physics states reuses a group
  that was already being loaded.
- `dialogue.json` is ~70KB on disk and decodes once into ~780 short strings.
- Persisted state is three small JSON files (memory, animation coverage, refresh
  log), all explicitly capped: 60 recent activations, 14 days of category
  rollups, 30 refresh entries, 12 generated lines per bucket.

## Not yet measured

These numbers are structural — derived from what the code schedules, verified by
reading every timer in the tree. They have **not** been confirmed against a
running instance with Instruments, because the app has not been launched (see
the note in the summary). The physics maths and the clock/policy/parser logic
*were* verified by executing them standalone.
