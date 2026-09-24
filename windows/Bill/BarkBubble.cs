using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Bill;

/// <summary>
/// Port of the Mac side's `BarkBubble`/`PixelFont` rendering — builds the
/// bubble as a pure-pixel WriteableBitmap: black outline, yellow accent
/// ring, white fill, rounded pixel-art corners, blocky tail, and the
/// hand-built 5x7 dot-matrix font. No font rendering, no antialiasing,
/// byte-for-byte the same look as the Mac bubble.
/// </summary>
public static class BarkBubble
{
    private const int PaddingX = 7;
    private const int PaddingY = 6;
    private const int CornerRadius = 5;
    private const int BorderThickness = 1;
    private const int AccentThickness = 1;
    private const int TailHeight = 5;
    private const int MaxTextWidthUnits = 66;
    private const int MinTextWidthUnits = 20;
    private const int MaxLines = 14;

    private static readonly Color Black = Color.FromRgb(0x1F, 0x1F, 0x22);
    private static readonly Color Yellow = Color.FromRgb(0xFA, 0xC7, 0x26);
    private static readonly Color Fill = Color.FromRgb(0xFA, 0xF9, 0xF5);

    private static uint ToPixel(Color c) => (uint)(0xFF << 24 | c.R << 16 | c.G << 8 | c.B);

    public static WriteableBitmap Make(string text, int maxWidthPx, float pixelScale, float tailOffsetUnits = 0)
    {
        // Column width from the caller's measured room (the Mac side's
        // availableBarkWidth logic lives in the caller).
        var chromeUnits = PaddingX * 2 + (BorderThickness + AccentThickness) * 2;
        var roomUnits = (int)MathF.Floor(maxWidthPx / pixelScale) - chromeUnits;
        var column = Math.Clamp(roomUnits, MinTextWidthUnits, MaxTextWidthUnits);

        var lines = Wrap(Normalize(text.ToUpperInvariant()), column, MaxLines);

        var blockWidth = lines.Count > 0 ? lines.Max(PixelFontWidth) : 0;
        var blockHeight = lines.Count * PixelFont.LineHeight - PixelFont.LineSpacing;

        var bodyWidth = blockWidth + PaddingX * 2;
        var bodyHeight = blockHeight + PaddingY * 2;
        var width = bodyWidth;
        var height = bodyHeight + TailHeight;

        var pixels = new uint[width * height];

        // Layered border: black → accent → fill, radius shrinking per layer —
        // the exact drawLayeredBorder recipe from the Mac side.
        FillPixelRoundedRect(pixels, width, height, 0, TailHeight, bodyWidth, bodyHeight, CornerRadius, Black);
        FillPixelRoundedRect(pixels, width, height,
            BorderThickness, TailHeight + BorderThickness,
            bodyWidth - BorderThickness * 2, bodyHeight - BorderThickness * 2,
            Math.Max(0, CornerRadius - BorderThickness), Yellow);
        var fillX = BorderThickness + AccentThickness;
        FillPixelRoundedRect(pixels, width, height,
            fillX, TailHeight + fillX,
            bodyWidth - fillX * 2, bodyHeight - fillX * 2,
            Math.Max(0, CornerRadius - BorderThickness - AccentThickness), Fill);

        // Tail, offset toward Bill when the bubble is shifted (same math as
        // the Mac side's tailOffsetUnits).
        var maxOffset = bodyWidth / 2f - 5;
        var midX = bodyWidth / 2f + Math.Clamp(tailOffsetUnits, -maxOffset, maxOffset);
        SetRect(pixels, width, height, (int)midX - 3, TailHeight - 2, 6, 2, ToPixel(Black));
        SetRect(pixels, width, height, (int)midX - 1, 0, 2, TailHeight - 2, ToPixel(Black));

        // Text: filled unit squares, each line horizontally centered.
        var blackP = ToPixel(Black);
        var blockH = lines.Count * PixelFont.LineHeight - PixelFont.LineSpacing;
        var y = (bodyHeight - blockH) / 2 + PaddingY;
        foreach (var line in lines)
        {
            var lw = PixelFontWidth(line);
            var x = (bodyWidth - lw) / 2f;
            DrawGlyphLine(line, (int)x, y + TailHeight, blackP, pixels, width, height);
            y += PixelFont.LineHeight;
        }

        var bmp = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
        bmp.WritePixels(new Int32Rect(0, 0, width, height), pixels, width * 4, 0);
        return bmp;
    }

    private static void SetRect(uint[] px, int surfaceW, int surfaceH, int x, int y, int w, int h, uint color)
    {
        for (var row = y; row < y + h && row < surfaceH; row++)
        {
            for (var col = x; col < x + w && col < surfaceW; col++)
            {
                if (row >= 0 && col >= 0) px[row * surfaceW + col] = color;
            }
        }
    }

    private static void DrawGlyphLine(string line, int originX, int originY, uint color, uint[] px, int surfaceW, int surfaceH)
    {
        var x = (float)originX;
        foreach (var ch in line)
        {
            if (ch != ' ' && PixelFont.Glyphs.TryGetValue(ch, out var rows))
            {
                for (var r = 0; r < PixelFont.GlyphHeight; r++)
                {
                    var bits = rows[r];
                    for (var c = 0; c < PixelFont.GlyphWidth; c++)
                    {
                        if (((bits >> (4 - c)) & 1) != 1) continue;
                        var pxX = (int)x + c;
                        var pxY = originY + PixelFont.GlyphHeight - 1 - r;
                        if (pxX >= 0 && pxY >= 0 && pxX < surfaceW && pxY < surfaceH)
                        {
                            px[pxY * surfaceW + pxX] = color;
                        }
                    }
                }
            }
            x += ch == ' ' ? PixelFont.SpaceWidth : PixelFont.GlyphWidth + PixelFont.GlyphSpacing;
        }
    }

    public static int PixelFontWidth(string line)
    {
        if (string.IsNullOrEmpty(line)) return 0;
        var total = line.Sum(ch => ch == ' ' ? PixelFont.SpaceWidth : PixelFont.GlyphWidth + PixelFont.GlyphSpacing);
        return total - PixelFont.GlyphSpacing;
    }

    /// Port of `PixelFont.wrap`: greedy word wrap with hard-break for
    /// overlong words, ellipsis-capped at maxLines.
    public static List<string> Wrap(string text, int maxWidthUnits, int maxLines)
    {
        var maxWidth = (float)maxWidthUnits;
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var lines = new List<string>();
        var current = "";
        foreach (var word in words)
        {
            var piece = HardBreak(word, maxWidth, lines, ref current);
            var candidate = current.Length == 0 ? piece : current + " " + piece;
            if (PixelFontWidth(candidate) > maxWidth && current.Length > 0)
            {
                lines.Add(current);
                current = piece;
            }
            else
            {
                current = candidate;
            }
        }
        if (current.Length > 0) lines.Add(current);
        if (lines.Count == 0) lines.Add("");
        if (lines.Count <= maxLines) return lines;

        var truncated = lines.Take(maxLines).ToList();
        var last = truncated[^1];
        truncated.RemoveAt(truncated.Count - 1);
        var trimmed = last;
        while (PixelFontWidth(trimmed + "...") > maxWidth && trimmed.Length > 0)
        {
            trimmed = trimmed[..^1];
        }
        truncated.Add(trimmed + "...");
        return truncated;
    }

    private static string HardBreak(string word, float maxWidth, List<string> lines, ref string current)
    {
        if (PixelFontWidth(word) <= maxWidth) return word;
        if (current.Length > 0)
        {
            lines.Add(current);
            current = "";
        }
        var chunk = "";
        foreach (var ch in word)
        {
            var candidate = chunk + ch;
            if (PixelFontWidth(candidate) > maxWidth && chunk.Length > 0)
            {
                lines.Add(chunk);
                chunk = ch.ToString();
            }
            else
            {
                chunk = candidate;
            }
        }
        return chunk;
    }

    /// Port of `BarkBubble.normalize`: the dot-matrix font has no curly
    /// quotes or em-dashes — map them to what it can draw.
    public static string Normalize(string text) => text
        .Replace('\u2018', '\'').Replace('\u2019', '\'')
        .Replace('\u201C', '"').Replace('\u201D', '"')
        .Replace('\u2013', '-').Replace('\u2014', '-');

    /// Port of `fillPixelRoundedRect`: quarter-circle mask per corner at
    /// unit-pixel granularity — the visible pixel-art staircase.
    private static void FillPixelRoundedRect(uint[] px, int surfaceW, int surfaceH,
        int x, int y, int w, int h, int radius, Color color)
    {
        if (w < 1 || h < 1) return;
        var cols = Math.Max(1, w);
        var rows = Math.Max(1, h);
        var r = Math.Clamp(radius, 0, Math.Min(cols, rows) / 2);
        var c = ToPixel(color);
        for (var row = 0; row < rows; row++)
        {
            var vCorner = Math.Min(row, rows - 1 - row);
            for (var col = 0; col < cols; col++)
            {
                var hCorner = Math.Min(col, cols - 1 - col);
                if (hCorner < r && vCorner < r)
                {
                    var di = r - hCorner - 0.5;
                    var dj = r - vCorner - 0.5;
                    if (di * di + dj * dj > r * r) continue;
                }
                var sx = x + col;
                var sy = y + row;
                if (sx >= 0 && sy >= 0 && sx < surfaceW && sy < surfaceH)
                {
                    px[sy * surfaceW + sx] = c;
                }
            }
        }
    }
}
