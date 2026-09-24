using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Bill;

/// <summary>
/// The pet window — milestone W1 (layered, always-on-top, per-pixel
/// click-through outside Bill's silhouette) now driven by the milestone-W2
/// brain: the full 66-family animation library plays through
/// `BillStateMachine`, and barks surface as pixel speech bubbles above him
/// (`BubbleWindow` + `BarkBubble`), voiced from the same dialogue.json the
/// Mac app reads. See Docs/notes/WindowsPortPlan.md for what comes next:
/// roaming physics, the chat bridge, and awareness.
/// </summary>
public partial class PetWindow : Window
{
    private const int WM_NCHITTEST = 0x0084;
    private const int HTTRANSPARENT = -1;
    private const int SpriteWidth = 118;
    private const int SpriteHeight = 111;
    private const byte AlphaThreshold = 40;
    private const float BubbleScale = 3f;

    private readonly DialogueLibrary _dialogue = new();
    private readonly BillStateMachine _state;
    private readonly BubbleWindow _bubble = new();
    private readonly byte[] _idleAlpha;
    private readonly DispatcherTimer _dragWalkReturn = new() { Interval = TimeSpan.FromSeconds(1.2) };

    public PetWindow()
    {
        InitializeComponent();
        RenderOptions.SetBitmapScalingMode(Sprite, BitmapScalingMode.NearestNeighbor);

        Left = SystemParameters.WorkArea.Right - Width - 40;
        Top = SystemParameters.WorkArea.Bottom - Height - 20;

        _state = new BillStateMachine(_dialogue);
        _state.OnFrame += frame => Dispatcher.Invoke(() => Sprite.Source = frame);
        _state.OnBark += text => Dispatcher.Invoke(() => ShowBark(text));

        _idleAlpha = ExtractAlpha(LoadFrame("bill_idle", 1));
        _dragWalkReturn.Tick += (_, _) => _state.Request("idle");

        Loaded += (_, _) => HookHitTest();
    }

    private void ShowBark(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        // The bubble is measured against a sensible desktop width; the
        // bitmap is composed at BubbleScale source pixels per unit.
        var bubble = BarkBubble.Make(text, maxWidthPx: 220, pixelScale: BubbleScale);
        _bubble.ShowAbove(this, bubble);
    }

    private static BitmapSource LoadFrame(string family, int index)
    {
        var bmp = new BitmapImage(new Uri($"pack://application:,,,/Sprites/{family}_{index:D2}.png"));
        BitmapSource frame = bmp.Format == System.Windows.Media.PixelFormats.Bgra32
            ? bmp
            : new System.Windows.Media.Imaging.FormatConvertedBitmap(bmp, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        frame.Freeze();
        return frame;
    }

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

        var raw = lParam.ToInt64();
        var screenX = (short)(raw & 0xFFFF);
        var screenY = (short)((raw >> 16) & 0xFFFF);
        var point = Sprite.PointFromScreen(new Point(screenX, screenY));

        var scale = SpriteScale.ScaleX;
        var px = (int)(point.X / scale);
        var py = (int)(point.Y / scale);
        if (px < 0 || py < 0 || px >= SpriteWidth || py >= SpriteHeight)
        {
            handled = true;
            return (IntPtr)HTTRANSPARENT;
        }
        if (_idleAlpha[py * SpriteWidth + px] < AlphaThreshold)
        {
            handled = true;
            return (IntPtr)HTTRANSPARENT;
        }
        return IntPtr.Zero;
    }

    private void OnSpriteLeftDown(object sender, MouseButtonEventArgs e)
    {
        _state.Request("walk");
        _dragWalkReturn.Stop();
        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // Drag cancelled by the system (focus theft etc.) — harmless.
        }
        finally
        {
            _dragWalkReturn.Start();
        }
    }

    private void OnSpriteRightUp(object sender, MouseButtonEventArgs e)
    {
        ContextMenu.IsOpen = true;
    }

    private void OnBarkNow(object sender, RoutedEventArgs e)
    {
        var line = _dialogue.FirstLine(new[]
        {
            "clock." + DialogueLibrary.CurrentTimeOfDay().ToString().ToLowerInvariant(),
            "day.greeting",
            "poked",
            "userReturned",
        });
        if (line != null) ShowBark(line);
    }

    private void OnRandomAnim(object sender, RoutedEventArgs e)
    {
        var all = AnimationCatalog.All;
        _state.Request(all[new Random().Next(all.Length)].Name);
    }

    private void OnAbout(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "Bill Cipher — Windows PREVIEW (port milestones W1+W2)\n\n" +
            "What works right now: the layered always-on-top window, " +
            "per-pixel click-through outside Bill's silhouette, the full " +
            "66-family animation library at authentic pacing, ambient " +
            "idle beats and rare events, and pixel speech bubbles voiced " +
            "from the same dialogue file the Mac app uses. Drag him around " +
            "— he walks while you drag.\n\n" +
            "What is NOT here yet (later milestones): chat, roaming " +
            "physics, app/window awareness, settings, the minimize prank.\n\n" +
            "Unofficial fan project. Bill Cipher & Gravity Falls © Disney.",
            "Windows Preview 0.2",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void OnQuit(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }
}
