// GENERATED from Sources/Bill/Animation/BarkBubble.swift's PixelFont table — do not
// hand-edit; regenerate instead. 5x7 dot-matrix glyphs, one byte per row,
// bit 4 = leftmost pixel, exactly as on the Mac side.
using System.Collections.Generic;

namespace Bill;

public static class PixelFont
{
    public const int GlyphWidth = 5;
    public const int GlyphHeight = 7;
    public const int GlyphSpacing = 1;
    public const int SpaceWidth = 4;
    public const int LineSpacing = 2;
    public const int LineHeight = GlyphHeight + LineSpacing;

    // Character -> 7 rows of a 5-bit mask (bit 4 = leftmost pixel).
    public static readonly IReadOnlyDictionary<char, byte[]> Glyphs = new Dictionary<char, byte[]>
    {
        ['A'] = new byte[] { 14, 17, 17, 31, 17, 17, 17 },
        ['B'] = new byte[] { 30, 17, 17, 30, 17, 17, 30 },
        ['C'] = new byte[] { 15, 16, 16, 16, 16, 16, 15 },
        ['D'] = new byte[] { 30, 17, 17, 17, 17, 17, 30 },
        ['E'] = new byte[] { 31, 16, 16, 30, 16, 16, 31 },
        ['F'] = new byte[] { 31, 16, 16, 30, 16, 16, 16 },
        ['G'] = new byte[] { 15, 16, 16, 23, 17, 17, 15 },
        ['H'] = new byte[] { 17, 17, 17, 31, 17, 17, 17 },
        ['I'] = new byte[] { 14, 4, 4, 4, 4, 4, 14 },
        ['J'] = new byte[] { 7, 2, 2, 2, 2, 18, 12 },
        ['K'] = new byte[] { 17, 18, 20, 24, 20, 18, 17 },
        ['L'] = new byte[] { 16, 16, 16, 16, 16, 16, 31 },
        ['M'] = new byte[] { 17, 27, 21, 17, 17, 17, 17 },
        ['N'] = new byte[] { 17, 25, 21, 19, 17, 17, 17 },
        ['O'] = new byte[] { 14, 17, 17, 17, 17, 17, 14 },
        ['P'] = new byte[] { 30, 17, 17, 30, 16, 16, 16 },
        ['Q'] = new byte[] { 14, 17, 17, 17, 21, 18, 13 },
        ['R'] = new byte[] { 30, 17, 17, 30, 20, 18, 17 },
        ['S'] = new byte[] { 15, 16, 16, 14, 1, 1, 30 },
        ['T'] = new byte[] { 31, 4, 4, 4, 4, 4, 4 },
        ['U'] = new byte[] { 17, 17, 17, 17, 17, 17, 14 },
        ['V'] = new byte[] { 17, 17, 17, 17, 17, 10, 4 },
        ['W'] = new byte[] { 17, 17, 17, 21, 21, 27, 17 },
        ['X'] = new byte[] { 17, 17, 10, 4, 10, 17, 17 },
        ['Y'] = new byte[] { 17, 17, 10, 4, 4, 4, 4 },
        ['Z'] = new byte[] { 31, 1, 2, 4, 8, 16, 31 },
        ['0'] = new byte[] { 14, 17, 19, 21, 25, 17, 14 },
        ['1'] = new byte[] { 4, 12, 4, 4, 4, 4, 14 },
        ['2'] = new byte[] { 14, 17, 1, 2, 4, 8, 31 },
        ['3'] = new byte[] { 30, 1, 1, 14, 1, 1, 30 },
        ['4'] = new byte[] { 2, 6, 10, 18, 31, 2, 2 },
        ['5'] = new byte[] { 31, 16, 16, 30, 1, 1, 30 },
        ['6'] = new byte[] { 6, 8, 16, 30, 17, 17, 14 },
        ['7'] = new byte[] { 31, 1, 2, 4, 4, 4, 4 },
        ['8'] = new byte[] { 14, 17, 17, 14, 17, 17, 14 },
        ['9'] = new byte[] { 14, 17, 17, 15, 1, 2, 12 },
        ['.'] = new byte[] { 0, 0, 0, 0, 0, 12, 12 },
        [','] = new byte[] { 0, 0, 0, 0, 0, 6, 8 },
        ['!'] = new byte[] { 4, 4, 4, 4, 4, 0, 4 },
        ['?'] = new byte[] { 14, 17, 1, 6, 4, 0, 4 },
        ['\''] = new byte[] { 12, 12, 8, 0, 0, 0, 0 },
        ['"'] = new byte[] { 27, 27, 10, 0, 0, 0, 0 },
        ['-'] = new byte[] { 0, 0, 0, 31, 0, 0, 0 },
        [':'] = new byte[] { 0, 4, 4, 0, 4, 4, 0 },
        [';'] = new byte[] { 0, 4, 4, 0, 4, 8, 0 },
        ['('] = new byte[] { 2, 4, 8, 8, 8, 4, 2 },
        [')'] = new byte[] { 8, 4, 2, 2, 2, 4, 8 },
        ['/'] = new byte[] { 1, 2, 2, 4, 8, 8, 16 },
        ['*'] = new byte[] { 0, 4, 21, 14, 21, 0, 0 },
        ['+'] = new byte[] { 0, 4, 4, 31, 4, 4, 0 },
        ['='] = new byte[] { 0, 0, 31, 0, 31, 0, 0 },
        ['%'] = new byte[] { 17, 1, 2, 4, 8, 16, 17 },
        ['\u2026'] = new byte[] { 0, 0, 0, 0, 0, 21, 0 },
    };
}
