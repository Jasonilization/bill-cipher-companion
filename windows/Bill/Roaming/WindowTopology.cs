using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Bill.Roaming;

/// <summary>
/// Win32 interop for the roaming milestone: the port plan's `EnumWindows` +
/// `DWMWA_EXTENDED_FRAME_BOUNDS` replacement for the Mac side's
/// `CGWindowListCopyWindowInfo`.
/// </summary>
internal static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int DWMWA_CLOAKED = 14;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
}

/// <summary>
/// Port of the Mac side's `WindowTopology` — the solid-window snapshot the
/// physics treats as furniture. Filters the same way the Mac version learned
/// to (see its own comment trail): only ordinary visible windows, never our
/// own, never cloaked/UWP-ghost frames, never tool windows, and every rect
/// clamped into the walkable work area — the menu-bar-stuck lesson applied
/// to the taskbar up front.
///
/// Coordinates: Win32 gives top-left-origin Y-down; this type converts to
/// the simulation's bottom-left-origin Y-up so nothing downstream has to
/// think about it again.
/// </summary>
internal sealed class WindowTopology
{
    public readonly struct Platform
    {
        public Platform(IntPtr hwnd, float minX, float minY, float maxX, float maxY)
        {
            Hwnd = hwnd; MinX = minX; MinY = minY; MaxX = maxX; MaxY = maxY;
        }
        public IntPtr Hwnd { get; }
        public float MinX { get; }
        public float MinY { get; }
        public float MaxX { get; }
        public float MaxY { get; }
        public float Width => MaxX - MinX;
        public float Height => MaxY - MinY;
    }

    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(5);
    private List<Platform> _cached = new();
    private DateTime _cachedAt = DateTime.MinValue;

    public IntPtr OwnHwnd1 { get; set; }
    public IntPtr OwnHwnd2 { get; set; }
    public uint OwnProcessId { get; set; }

    /// The walkable work area in screen coordinates (top-left origin,
    /// Y-down), set by the controller each snapshot.
    public System.Windows.Rect WorkAreaDown { get; set; }

    public List<Platform> Snapshot(bool fresh = false)
    {
        if (!fresh && DateTime.UtcNow - _cachedAt < CacheLifetime) return _cached;
        _cached = Build();
        _cachedAt = DateTime.UtcNow;
        return _cached;
    }

    private List<Platform> Build()
    {
        var result = new List<Platform>();
        if (OwnProcessId == 0) return result;

        // Work area converted to the sim's Y-up space.
        float YDownToUp(float yDown) => (float)(WorkAreaDown.Top + WorkAreaDown.Height - yDown);

        NativeMethods.EnumWindowsProc collect = (hwnd, _) =>
        {
            if (hwnd == OwnHwnd1 || hwnd == OwnHwnd2) return true;
            NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == OwnProcessId) return true;
            if (!NativeMethods.IsWindowVisible(hwnd)) return true;
            var exStyle = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
            if ((exStyle & NativeMethods.WS_EX_TOOLWINDOW) != 0) return true;

            // Cloaked windows (UWP ghosts, virtual-desktop members) are
            // "visible" to Win32 but not actually on this desktop.
            int cloaked;
            if (NativeMethods.DwmGetWindowAttribute(hwnd, NativeMethods.DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0
                && cloaked != 0) return true;

            // DWM's extended bounds are the *visual* frame — what the user
            // sees and what Bill should stand on; GetWindowRect includes
            // invisible resize borders.
            NativeMethods.RECT r;
            if (NativeMethods.DwmGetWindowAttribute(hwnd, NativeMethods.DWMWA_EXTENDED_FRAME_BOUNDS,
                    out r, System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.RECT>()) != 0)
            {
                if (!NativeMethods.GetWindowRect(hwnd, out r)) return true;
            }

            var minX = (float)r.Left;
            var maxX = (float)r.Right;
            var minY = (float)r.Bottom;   // Y-down bottom -> Y-up lower edge
            var maxY = (float)r.Top;      // Y-down top -> Y-up upper edge

            // Clamp into the walkable work area before anything else — the
            // Mac side's "no solid above the ceiling" rule, which is what
            // finally killed the stuck-under-the-menu-bar class of bug.
            var areaMinX = (float)WorkAreaDown.Left;
            var areaMaxX = (float)WorkAreaDown.Right;
            var areaMinY = (float)0;                          // work-area floor
            var areaMaxY = YDownToUp((float)WorkAreaDown.Top); // work-area top, Y-up

            minX = MathF.Max(minX, areaMinX);
            maxX = MathF.Min(maxX, areaMaxX);
            minY = MathF.Max(minY, areaMinY);
            maxY = MathF.Min(maxY, areaMaxY);
            if (maxX - minX < 160 || maxY - minY < 24) return true; // slivers are not furniture

            result.Add(new Platform(hwnd, minX, minY, maxX, maxY));
            return true;
        };

        NativeMethods.EnumWindows(collect, IntPtr.Zero);

        // Front-to-back: EnumWindows is topmost-first, which is exactly the
        // front-to-back order the Mac side's CGWindowList gives.
        return result;
    }
}
