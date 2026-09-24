using System.Windows;

namespace Bill;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new PetWindow();
        window.Show();
    }
}
