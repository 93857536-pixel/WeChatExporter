using System.Windows;
using WeChatExporter.Services;

namespace WeChatExporter;

/// <summary>首次启动的「诊断日志上传」条款弹窗：同意写 true，不同意写 false。</summary>
public partial class ConsentWindow : Window
{
    public ConsentWindow()
    {
        InitializeComponent();
    }

    private void Agree_Click(object sender, RoutedEventArgs e)
    {
        DiagnosticUploader.SetConsent(true);
        DialogResult = true;
    }

    private void Decline_Click(object sender, RoutedEventArgs e)
    {
        DiagnosticUploader.SetConsent(false);
        DialogResult = false;
    }
}
