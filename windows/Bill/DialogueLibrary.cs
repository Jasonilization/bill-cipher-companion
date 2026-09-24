using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Bill;

public enum TimeOfDay { Morning, Midday, Afternoon, Night }

/// <summary>
/// Port of `DialogueLibrary`/`DialoguePool`/`TimeOfDay` from the Mac side —
/// deliberately reading the *same* dialogue.json the Mac app uses (copied
/// into the project as a resource), so the two apps speak identically until
/// the personalized/generated halves get their Windows-side stores in a
/// later milestone.
/// </summary>
public class DialogueLibrary
{
    public sealed class Pool
    {
        public List<string> Any { get; set; } = new();
        public List<string> Morning { get; set; } = new();
        public List<string> Midday { get; set; } = new();
        public List<string> Afternoon { get; set; } = new();
        public List<string> Night { get; set; } = new();

        public List<string> Bucket(TimeOfDay t) => t switch
        {
            TimeOfDay.Morning => Morning,
            TimeOfDay.Midday => Midday,
            TimeOfDay.Afternoon => Afternoon,
            _ => Night,
        };

        /// Same "specific lines alone when the bucket can carry the pool"
        /// rule as `DialoguePool.lines(for:)`.
        public List<string> LinesFor(TimeOfDay t)
        {
            var specific = Bucket(t);
            if (specific.Count >= 3) return specific;
            if (specific.Count == 0) return Any;
            return specific.Concat(Any).ToList();
        }
    }

    private readonly Dictionary<string, Pool> _pools = new();
    private readonly Dictionary<string, string> _lastLine = new();
    private static readonly Random _rng = new();

    public static TimeOfDay CurrentTimeOfDay()
    {
        var hour = DateTime.Now.Hour;
        return hour switch
        {
            >= 5 and < 11 => TimeOfDay.Morning,
            >= 11 and < 15 => TimeOfDay.Midday,
            >= 15 and < 21 => TimeOfDay.Afternoon,
            _ => TimeOfDay.Night,
        };
    }

    public DialogueLibrary()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Dialogue", "dialogue.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        foreach (var entry in doc.RootElement.EnumerateObject())
        {
            var pool = new Pool();
            if (entry.Value.TryGetProperty("any", out var any)) pool.Any = Strings(any);
            if (entry.Value.TryGetProperty("morning", out var m)) pool.Morning = Strings(m);
            if (entry.Value.TryGetProperty("midday", out var md)) pool.Midday = Strings(md);
            if (entry.Value.TryGetProperty("afternoon", out var a)) pool.Afternoon = Strings(a);
            if (entry.Value.TryGetProperty("night", out var n)) pool.Night = Strings(n);
            _pools[entry.Name] = pool;
        }
    }

    private static List<string> Strings(JsonElement e) =>
        e.EnumerateArray().Select(v => v.GetString() ?? "").ToList();

    /// First pool among `keys` with content — the fallback-ladder rule.
    public string? FirstLine(IEnumerable<string> keys)
    {
        foreach (var key in keys)
        {
            var line = Line(key);
            if (line != null) return line;
        }
        return null;
    }

    /// A line for `key`, honoring the time bucket and never repeating the
    /// last line served for that key.
    public string? Line(string key)
    {
        if (!_pools.TryGetValue(key, out var pool)) return null;
        var candidates = pool.LinesFor(CurrentTimeOfDay());
        if (candidates.Count == 0) return null;
        var pool2 = candidates;
        if (pool2.Count > 1 && _lastLine.TryGetValue(key, out var last))
        {
            pool2 = pool2.Where(l => l != last).ToList();
        }
        var chosen = pool2[_rng.Next(pool2.Count)];
        _lastLine[key] = chosen;
        return chosen;
    }

    public int PoolCount => _pools.Count;
    public IEnumerable<string> Keys => _pools.Keys;
}
