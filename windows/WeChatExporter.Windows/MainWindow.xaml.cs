using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using WeChatExporter.Models;
using WeChatExporter.Services;
using WeChatExporter.ViewModels;

namespace WeChatExporter;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();

        var wxCli = WxCliService.TryCreate()
            ?? throw new InvalidOperationException(
                "未找到 wx-cli。请重新安装应用，或确认 wx.exe 位于程序目录。");

        // 首次启动：用户尚未就「诊断日志上传」做出选择时，先弹出条款窗。
        if (!DiagnosticUploader.HasConsent)
            new ConsentWindow().ShowDialog();

        _viewModel = new MainViewModel(wxCli);
        DataContext = _viewModel;
    }

    private void ContactList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _viewModel.SelectedContacts.Clear();
        foreach (ContactItem item in ContactList.SelectedItems)
            _viewModel.SelectedContacts.Add(item);
        _viewModel.NotifySelectionChanged();
    }

    private async void PrepareData_Click(object sender, RoutedEventArgs e)
        => await _viewModel.PrepareDataAsync();

    private async void Refresh_Click(object sender, RoutedEventArgs e)
        => await _viewModel.RefreshContactsAsync();

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        // 导出前从密码框取当前密码（非空即启用加密导出；留空 = 明文目录）
        if (!string.IsNullOrEmpty(PwdBox.Password))
            _viewModel.ExportPassword = PwdBox.Password;
        await _viewModel.ExportSelectedAsync();
    }

    // #39：取消当前长任务（后台线程收到取消后快速返回，UI 恢复可交互）
    private void Cancel_Click(object sender, RoutedEventArgs e)
        => _viewModel.CancelOperation();

    private void SetPassword_Click(object sender, RoutedEventArgs e)
    {
        // 同步到 ViewModel：下次「导出选中」时生效（非空加密，空 = 明文）
        _viewModel.ExportPassword = PwdBox.Password;
    }

    private async void DecryptExport_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(PwdBox.Password))
            _viewModel.ExportPassword = PwdBox.Password;
        await _viewModel.DecryptEncryptedExport();
    }

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
        => _viewModel.ChooseExportFolder();

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
        => _viewModel.OpenExportFolder();

    private void RestartAdmin_Click(object sender, RoutedEventArgs e)
        => _viewModel.RestartAsAdministrator();

    private async void DownloadWhisperModel_Click(object sender, RoutedEventArgs e)
        => await _viewModel.DownloadWhisperModelAsync();

    // MARK: - v2.19 新功能事件

    private void Search_Click(object sender, RoutedEventArgs e)
        => _viewModel.RunSearch();

    private void RebuildIndex_Click(object sender, RoutedEventArgs e)
        => _viewModel.RebuildSearchIndex();

    private void SearchResultsList_MouseDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (SearchResultsList.SelectedItem is SearchIndexService.Hit hit)
            _viewModel.OpenSearchHit(hit);
    }

    private void InstallAutoSync_Click(object sender, RoutedEventArgs e)
        => _viewModel.InstallAutoSyncTask();

    private void UninstallAutoSync_Click(object sender, RoutedEventArgs e)
        => _viewModel.UninstallAutoSyncTask();
}

public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is bool b ? !b : true;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => value is bool b ? !b : false;
}

/// <summary>管理员已运行时隐藏「以管理员重启」按钮。</summary>
public sealed class AdminRestartVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is bool isAdmin && !isAdmin ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
