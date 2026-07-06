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
        => await _viewModel.ExportSelectedAsync();

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
        => _viewModel.ChooseExportFolder();

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
        => _viewModel.OpenExportFolder();
}

public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is bool b ? !b : true;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => value is bool b ? !b : false;
}
