using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Bill;

/// <summary>
/// Port of the playback half of the Mac side's `BillStateMachine` +
/// `BillSpriteCatalog`: every one of the 66 animation families, played at
/// their authentic frame durations, one-shot states settling back to idle,
/// an ambient idle-variant rotation, and a bark queue that keeps lines
/// readable instead of overwriting each other.
///
/// Later milestones port the *reaction* wiring (roaming, awareness); this
/// milestone makes the whole library genuinely playable and voiced.
/// </summary>
public class BillStateMachine
{
    private readonly Dictionary<string, BitmapSource[]> _frames = new();
    private readonly DispatcherTimer _frameTimer = new();
    private readonly DispatcherTimer _idleBeat = new();
    private readonly DialogueLibrary _dialogue;

    private string _current = "idle";
    private bool _loopCurrent = true;
    private int _frameIndex;
    private DateTime _clipStartedAt;
    private string? _pendingSettleState;

    // The family subset used for ambient rotation — matches the Mac side's
    // `AnimationClipLibrary` idle-variant pool plus a few personality
    // beats that read well from rest.
    private static readonly string[] IdleVariants =
    {
        "curious", "focused", "smug", "thinking", "confused", "happy", "cane", "canetwist",
    };
    private static readonly string[] RareEggs =
    {
        "powersurge", "powersurgeclose", "portalring", "zodiac", "summonritual", "ritualBuildup",
        "ghost", "glitch", "shadowa", "shadowb", "meltdown", "tumbling", "dashtarget",
        "ziparound", "rampaging", "conjuring",
    };
    private static readonly Random Rng = new();

    /// Fired when a bark should be shown (text) — the window layer owns
    /// bubble placement.
    public event Action<string>? OnBark;

    /// Fired whenever the sprite frame advances — the window swaps its Image.
    public event Action<BitmapSource>? OnFrame;

    public BillStateMachine(DialogueLibrary dialogue)
    {
        _dialogue = dialogue;
        foreach (var family in AnimationCatalog.All)
        {
            var frames = new BitmapSource[family.FrameCount];
            for (int i = 1; i <= family.FrameCount; i++)
            {
                var uri = new Uri($"pack://application:,,,/Sprites/{family.Prefix}_{i:D2}.png");
                var bmp = new BitmapImage(uri);
                BitmapSource frame = bmp.Format == System.Windows.Media.PixelFormats.Bgra32
                    ? bmp
                    : new System.Windows.Media.Imaging.FormatConvertedBitmap(bmp, System.Windows.Media.PixelFormats.Bgra32, null, 0);
                frame.Freeze();
                frames[i - 1] = frame;
            }
            _frames[family.Name] = frames;
        }

        _frameTimer.Tick += (_, _) => AdvanceFrame();
        _idleBeat.Interval = TimeSpan.FromSeconds(Rng.Next(8, 16));
        _idleBeat.Tick += (_, _) => AmbientBeat();
        Play("idle");
        _idleBeat.Start();
    }

    public string CurrentState => _current;

    /// Plays `state` once, then settles back to the idle loop (the Mac
    /// side's `.once` clips returning to rest). Unknown names are ignored.
    public void Request(string state)
    {
        if (!_frames.ContainsKey(state)) return;
        Play(state, loop: false, settleTo: "idle");
    }

    /// Ambient rotation: idle variants most beats, a rare egg 10% of the
    /// time, and a time-of-day bark from the clock pools ~35% of beats —
    /// the preview's proof that the dialogue half is alive.
    private void AmbientBeat()
    {
        _idleBeat.Interval = TimeSpan.FromSeconds(Rng.Next(8, 16));
        if (_current != "idle") return;

        if (Rng.NextDouble() < 0.10)
        {
            var egg = RareEggs[Rng.Next(RareEggs.Length)];
            Play(egg, loop: false, settleTo: "idle");
            OnBark?.Invoke(_dialogue.Line(egg) ?? "");
            return;
        }

        var variant = IdleVariants[Rng.Next(IdleVariants.Length)];
        Play(variant, loop: false, settleTo: "idle");

        if (Rng.NextDouble() < 0.35)
        {
            var line = _dialogue.FirstLine(new[]
            {
                "clock." + DialogueLibrary.CurrentTimeOfDay().ToString().ToLowerInvariant(),
                "day.greeting",
                "userReturned",
            });
            if (line != null) OnBark?.Invoke(line);
        }
    }

    private void Play(string state, bool loop = true, string? settleTo = null)
    {
        if (!_frames.ContainsKey(state)) state = "idle";
        _current = state;
        _loopCurrent = loop;
        _pendingSettleState = loop ? null : settleTo;
        _frameIndex = 0;
        _clipStartedAt = DateTime.UtcNow;
        _frameTimer.Interval = TimeSpan.FromMilliseconds(ByName(state)!.FrameMs);
        ShowCurrentFrame();
        _frameTimer.Start();
    }

    private void AdvanceFrame()
    {
        var frames = _frames[_current];
        _frameIndex++;

        if (_frameIndex >= frames.Length)
        {
            if (_loopCurrent)
            {
                _frameIndex = 0;
            }
            else
            {
                // Hold the final frame ~8 extra beats — the Mac side's
                // `holdLast(extra:)` — then settle.
                var elapsed = DateTime.UtcNow - _clipStartedAt;
                var holdMs = 8L * ByName(_current)!.FrameMs;
                if (elapsed > TimeSpan.FromMilliseconds(frames.Length * ByName(_current)!.FrameMs + holdMs))
                {
                    if (_pendingSettleState != null)
                    {
                        Play(_pendingSettleState);
                    }
                    return;
                }
                _frameIndex = frames.Length - 1;
            }
        }
        ShowCurrentFrame();
    }

    private void ShowCurrentFrame()
    {
        var frames = _frames[_current];
        OnFrame?.Invoke(frames[Math.Clamp(_frameIndex, 0, frames.Length - 1)]);
    }

    private static AnimFamily? ByName(string name) => AnimationCatalog.ByName(name);
}
