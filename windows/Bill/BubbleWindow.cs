using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Bill;

/// <summary>
/// A separate layered window for the bark bubble, positioned just above
/// the pet window — fully click-through in both directions so it never
/// blocks the desktop, fading in/out like the Mac side's bark.
/// </summary>
public class BubbleWindow : Window
{
    private const int WM_NCHITTEST = 0x0084;
    private const int HTTRANSPARENT = -1;
    private const float BubblePixelScale = 2f;

    private readonly Image _image = new() { Stretch = Stretch.None };
    private DispatcherTimer? _dismiss;

    public BubbleWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
        Content = _image;
        Opacity = 0;
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.NearestNeighbor);
    }

    /// Shows `bubble` centered above the pet window, fading in, then out
    /// after a readable duration scaled to the text amount.
    public void ShowAbove(Window pet, WriteableBitmap bubble)
    {
        _dismiss?.Stop();

        Width = bubble.PixelWidth * BubblePixelScale;
        Height = bubble.PixelHeight * BubblePixelScale;
        _image.Source = bubble;
        _image.LayoutTransform = new ScaleTransform(BubblePixelScale, BubblePixelScale);

        Left = pet.Left + (pet.Width - Width) / 2;
        Top = pet.Top - Height - 6;

        Opacity = 0;
        Show();
        Fade(0.22, 1);

        var seconds = Math.Clamp(1.8 + bubble.PixelHeight * 0.012, 2.2, 6.0);
        _dismiss = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        _dismiss.Tick += (_, _) =>
        {
            _dismiss.Stop();
            Fade(0.3, 0, hide: true);
        };
        _dismiss.Start();
    }

    private void Fade(double seconds, double to, bool hide = false)
    {
        var start = Opacity;
        var t = 0.0;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) =>
        {
            t += 0.016 / seconds;
            Opacity = start + (to - start) * Math.Min(1, t);
            if (t < 1) return;
            timer.Stop();
            if (hide) Hide();
        };
        timer.Start();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_NCHITTEST)
        {
            // The bubble is never interactive — all clicks pass through.
            handled = true;
            return (IntPtr)HTTRANSPARENT;
        }
        return IntPtr.Zero;
    }
}
