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

        _viewModel = new MainViewModel(wxCli);
        DataContext = _viewModel;
        ThemeManager.Apply(AppSettings.Shared.Appearance, this);
    }

    private void ContactList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // 导出/准备数据期间忽略选中变化，避免弹窗抢焦点导致选中被改写、下次导出串到其他人。
        if (_viewModel.IsBusy) return;

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
        => await _viewModel.ExportSelectedAsync();

    private async void Preview_Click(object sender, RoutedEventArgs e)
        => await _viewModel.PreviewSelectedAsync();

    private async void RetryFailed_Click(object sender, RoutedEventArgs e)
        => await _viewModel.RetryFailedAsync();

    private async void EnvironmentCheck_Click(object sender, RoutedEventArgs e)
        => await _viewModel.EnvironmentCheckAsync();

    private void ToggleFavorite_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ContactItem item })
        {
            _viewModel.ToggleFavorite(item);
            e.Handled = true;
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var win = new SettingsWindow(_viewModel) { Owner = this };
        win.ShowDialog();
        ThemeManager.Apply(AppSettings.Shared.Appearance, this);
    }

    private void RestartAdmin_Click(object sender, RoutedEventArgs e)
        => _viewModel.RestartAsAdministrator();
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
