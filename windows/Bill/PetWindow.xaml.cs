using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Bill;

/// <summary>
/// Milestone W1 of the Windows port (see Docs/notes/WindowsPortPlan.md):
/// a layered, always-on-top, click-through-outside-the-silhouette window
/// playing Bill's pixel sprites — the macOS panel equivalent.
///
/// Deliberately preview-scoped: idle + walk cycles, drag-to-move with the
/// walk animation, per-pixel hit-testing, a context menu. Chat, awareness,
/// roaming physics and settings are later milestones and intentionally
/// absent, and the app says so plainly rather than shipping dead buttons.
/// </summary>
public partial class PetWindow : Window
{
    private const int WM_NCHITTEST = 0x0084;
    private const int HTTRANSPARENT = -1;

    // Frame pacing mirrors the macOS clip library exactly.
    private static readonly TimeSpan IdleFrame = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan WalkFrame = TimeSpan.FromMilliseconds(140);
    private static readonly TimeSpan WalkCooldown = TimeSpan.FromSeconds(2.5);

    private readonly DispatcherTimer _timer = new() { Interval = IdleFrame };
    private readonly BitmapSource[] _idleFrames;
    private readonly BitmapSource[] _walkFrames;
    private readonly byte[] _idleAlpha;
    private int _frameIndex;
    private bool _walking;
    private readonly DispatcherTimer _walkReturn = new() { Interval = WalkCooldown };

    private const int SpriteWidth = 118;
    private const int SpriteHeight = 111;

    public PetWindow()
    {
        InitializeComponent();
        _idleFrames = LoadFrames("bill_idle", 7);
        _walkFrames = LoadFrames("bill_walk", 6);
        _idleAlpha = ExtractAlpha(_idleFrames[0]);

        Left = SystemParameters.WorkArea.Right - Width - 40;
        Top = SystemParameters.WorkArea.Bottom - Height - 20;

        _timer.Tick += (_, _) => AdvanceFrame();
        _walkReturn.Tick += (_, _) => SwitchToWalking(false);
        _timer.Start();
        Sprite.Source = _idleFrames[0];

        Loaded += (_, _) => HookHitTest();
    }

    private static BitmapSource[] LoadFrames(string family, int count)
    {
        var frames = new BitmapSource[count];
        for (int i = 1; i <= count; i++)
        {
            var uri = new Uri($"pack://application:,,,/Sprites/{family}_{i:D2}.png");
            var bmp = new BitmapImage(uri);
            // Everything downstream (hit-test alpha, rendering) wants
            // BGRA32; the sprites are plain RGBA PNGs.
            BitmapSource frame = bmp.Format == PixelFormats.Bgra32
                ? bmp
                : new FormatConvertedBitmap(bmp, PixelFormats.Bgra32, null, 0);
            frame.Freeze();
            frames[i - 1] = frame;
        }
        return frames;
    }

    /// <summary>
    /// The first idle frame's alpha channel, for per-pixel click-through:
    /// outside the silhouette the window is HTTRANSPARENT so clicks reach
    /// the desktop, inside it he is grabbable — the same rule the macOS
    /// app's `BillHitTestView` enforces.
    /// </summary>
    private static byte[] ExtractAlpha(BitmapSource frame)
    {
        var pixels = new byte[SpriteWidth * SpriteHeight * 4];
        frame.CopyPixels(pixels, SpriteWidth * 4, 0);
        var alpha = new byte[SpriteWidth * SpriteHeight];
        for (int p = 0; p < alpha.Length; p++)
        {
            alpha[p] = pixels[p * 4 + 3];
        }
        return alpha;
    }

    private void HookHitTest()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_NCHITTEST)
        {
            return IntPtr.Zero;
        }

        // lParam packs screen coordinates in the low/high 16 bits.
        var raw = lParam.ToInt64();
        var screenX = (short)(raw & 0xFFFF);
        var screenY = (short)((raw >> 16) & 0xFFFF);
        var point = Sprite.PointFromScreen(new Point(screenX, screenY));

        // Window DIP -> sprite source pixels (sprite is scaled 2x, and the
        // window may be DPI-scaled above that — Visual.PointFromScreen
        // returns DIPs, so dividing by the layout scale lands in source
        // space).
        var scale = SpriteScale.ScaleX;
        var px = (int)(point.X / scale);
        var py = (int)(point.Y / scale);
        if (px < 0 || py < 0 || px >= SpriteWidth || py >= SpriteHeight)
        {
            handled = true;
            return (IntPtr)HTTRANSPARENT;
        }
        const byte alphaThreshold = 40;
        if (_idleAlpha[py * SpriteWidth + px] < alphaThreshold)
        {
            handled = true;
            return (IntPtr)HTTRANSPARENT;
        }
        return IntPtr.Zero;
    }

    private void AdvanceFrame()
    {
        var frames = _walking ? _walkFrames : _idleFrames;
        _frameIndex = (_frameIndex + 1) % frames.Length;
        Sprite.Source = frames[_frameIndex];
        _timer.Interval = _walking ? WalkFrame : IdleFrame;
    }

    private void SwitchToWalking(bool walking)
    {
        if (_walking == walking)
        {
            return;
        }
        _walking = walking;
        _frameIndex = 0;
        _walkReturn.Stop();
        if (walking)
        {
            _walkReturn.Start();
        }
    }

    private void OnSpriteLeftDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        SwitchToWalking(true);
        DragMove();
    }

    private void OnSpriteRightUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        ContextMenu.IsOpen = true;
    }

    private void OnWalkDemo(object sender, RoutedEventArgs e)
    {
        SwitchToWalking(true);
    }

    private void OnAbout(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "Bill Cipher — Windows PREVIEW (port milestone W1)\n\n" +
            "What works right now: the layered always-on-top window, " +
            "per-pixel click-through outside Bill's silhouette, idle and " +
            "walk animation, drag-to-move (he walks while you drag).\n\n" +
            "What is NOT here yet (later milestones): chat, roaming " +
            "physics, awareness, settings, the minimize prank.\n\n" +
            "Unofficial fan project. Bill Cipher & Gravity Falls © Disney.",
            "Windows Preview",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void OnQuit(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
